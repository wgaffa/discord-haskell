{-# LANGUAGE OverloadedStrings #-}

-- | Provides logic code for interacting with the Discord websocket
--   gateway. Realistically, this is probably lower level than most
--   people will need
module Discord.Internal.Gateway.EventLoop where

import Prelude hiding (log)

import Control.Monad (forever)
import Control.Monad.Random (getRandomR)
import Control.Concurrent.Async (race)
import Control.Concurrent.Chan
import Control.Concurrent (threadDelay, killThread, forkIO)
import Control.Exception.Safe (try, finally, SomeException)
import Data.IORef
import Data.Aeson (eitherDecode, encode)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL

import Wuss (runSecureClient)
import Network.WebSockets (ConnectionException(..), Connection,
                           receiveData, sendTextData)

import Discord.Internal.Types


data GatewayException = GatewayExceptionCouldNotConnect T.Text
                      | GatewayExceptionEventParseError T.Text T.Text
                      | GatewayExceptionUnexpected GatewayReceivable T.Text
                      | GatewayExceptionConnection ConnectionException T.Text
  deriving (Show)

data ConnLoopState = ConnStart
                   | ConnClosed
                   | ConnReconnect T.Text Integer
  deriving Show

-- | Securely run a connection IO action. Send a close on exception
connect :: (Connection -> IO a) -> IO a
connect = runSecureClient "gateway.discord.gg" 443 "/?v=6&encoding=json"


data GatewayHandle = GatewayHandle
  { gatewayHandleEvents         :: Chan (Either GatewayException Event)
  , gatewayHandleUserSendables  :: Chan GatewaySendable
  , gatewayHandleLastStatus     :: IORef (Maybe UpdateStatusOpts)
  , gatewayHandleLastSequenceId :: IORef Integer
  , gatewayHandleSessionId      :: IORef T.Text
  }


{-
Auth                                                         needed to connect
GatewayIntent                                                needed to connect
GatewayHandle (events,status,usersends)                      needed all over
log :: Chan (T.Text)                                         needed all over

channelSends :: Chan (GatewaySendableInternal)
mvar heartbeatInterval :: Int                     set by Hello,  need heartbeat
sequenceId :: Int id of last event received       set by Resume, need reconnect and heartbeat
sessionId :: Text                                 set by Ready,  need reconnect

-}

data NextState = DoStart
               | DoClosed
               | DoReconnect
  deriving Show

data SendablesData = SendablesData
  { sendableConnection :: Connection
  , librarySendales :: Chan GatewaySendableInternal
  , startsendingUsers :: IORef Bool
  , heartbeatInterval :: Integer
  }

connectionLoop :: Auth -> GatewayIntent -> GatewayHandle -> Chan T.Text -> IO ()
connectionLoop auth intent gatewayHandle log = outerloop DoStart
  where

  outerloop :: NextState -> IO ()
  outerloop state = do
      mfirst <- firstmessage state
      case mfirst of
        Nothing -> pure ()
        Just first -> do
            next <- try (startconnectionpls first)
            case next :: Either SomeException NextState of
              Left _ -> do t <- getRandomR (3,20)
                           threadDelay (t * (10^(6 :: Int)))
                           writeChan log ("gateway - trying to reconnect after failure(s)")
                           outerloop DoReconnect
              Right n -> outerloop n

  firstmessage :: NextState -> IO (Maybe GatewaySendableInternal)
  firstmessage state =
    case state of
      DoStart -> pure $ Just $ Identify auth intent (0, 1)
      DoReconnect -> do seqId  <- readIORef (gatewayHandleLastSequenceId gatewayHandle)
                        seshId <- readIORef (gatewayHandleSessionId gatewayHandle)
                        pure $ Just $ Resume auth seshId seqId
      DoClosed -> pure Nothing

  startconnectionpls :: GatewaySendableInternal -> IO NextState
  startconnectionpls first = connect $ \conn -> do
                      msg <- getPayload conn log
                      case msg of
                        Right (Hello interval) -> do

                          internal <- newChan :: IO (Chan GatewaySendableInternal)
                          us <- newIORef False
                          -- start event loop
                          let sending = SendablesData conn internal us interval
                          sendsId <- forkIO $ sendableLoop conn gatewayHandle sending log
                          heart <- forkIO $ heartbeat internal interval
                                              (gatewayHandleLastSequenceId gatewayHandle)

                          writeChan internal first
                          finally (theloop gatewayHandle sending log)
                                  (killThread heart >> killThread sendsId)
                        _ -> do
                          writeChan (gatewayHandleEvents gatewayHandle)
                                    (Left (GatewayExceptionCouldNotConnect
                                       "Gateway could not connect. Expected hello"))
                          pure DoClosed


theloop :: GatewayHandle -> SendablesData -> Chan T.Text -> IO NextState
theloop thehandle sendablesData log = do loop
  where
  eventChan = gatewayHandleEvents thehandle

  loop = do
    eitherPayload <- getPayloadTimeout sendablesData log
    case eitherPayload :: Either ConnectionException GatewayReceivable of
      Right (Hello _interval) -> do writeChan log ("eventloop - unexpected hello")
                                    loop
      Right (Dispatch event sq) -> do writeIORef (gatewayHandleLastSequenceId thehandle) sq
                                      writeChan eventChan (Right event)
                                      case event of
                                        (Ready _ _ _ _ seshID) ->
                                            writeIORef (gatewayHandleSessionId thehandle) seshID
                                        _ -> writeIORef (startsendingUsers sendablesData) True
                                      loop
      Right (HeartbeatRequest sq) -> do writeIORef (gatewayHandleLastSequenceId thehandle) sq
                                        writeChan (librarySendales sendablesData) (Heartbeat sq)
                                        loop
      Right (Reconnect)      -> pure DoReconnect
      Right (InvalidSession retry) -> pure $ if retry then DoReconnect else DoStart
      Right (HeartbeatAck)   -> loop
      Right (ParseError e) -> do writeChan eventChan (Left (GatewayExceptionEventParseError e
                                                             "Normal event loop"))
                                 pure DoClosed
      Left (CloseRequest code str) -> case code of
          -- see Discord and MDN documentation on gateway close event codes
          -- https://discord.com/developers/docs/topics/opcodes-and-status-codes#gateway-gateway-close-event-codes
          -- https://developer.mozilla.org/en-US/docs/Web/API/CloseEvent#properties
          1000 -> pure DoReconnect
          1001 -> pure DoReconnect
          4000 -> pure DoReconnect
          4006 -> pure DoStart
          4007 -> pure DoReconnect
          4014 -> do writeChan eventChan (Left (GatewayExceptionUnexpected (Hello 0) $
                           "Tried to declare an unauthorized GatewayIntent. " <>
                           "Use the discord app manager to authorize by following: " <>
                           "https://github.com/aquarial/discord-haskell/issues/76"))
                     pure DoClosed
          _ -> do writeChan eventChan (Left (GatewayExceptionConnection (CloseRequest code str)
                                              "Normal event loop close request"))
                  pure DoClosed
      Left _ -> pure DoReconnect


heartbeat :: Chan GatewaySendableInternal -> Integer -> IORef Integer -> IO ()
heartbeat send interval seqKey = do
  threadDelay (3 * 10^(6 :: Int))
  forever $ do
    num <- readIORef seqKey
    writeChan send (Heartbeat num)
    threadDelay (fromInteger (interval * 1000))

getPayloadTimeout :: SendablesData -> Chan T.Text -> IO (Either ConnectionException GatewayReceivable)
getPayloadTimeout sendablesData log = do
  let interval = heartbeatInterval sendablesData
  res <- race (threadDelay (fromInteger ((interval * 1000 * 3) `div` 2)))
              (getPayload (sendableConnection sendablesData) log)
  case res of
    Left () -> pure (Right Reconnect)
    Right other -> pure other

getPayload :: Connection -> Chan T.Text -> IO (Either ConnectionException GatewayReceivable)
getPayload conn log = try $ do
  msg' <- receiveData conn
  case eitherDecode msg' of
    Right msg -> pure msg
    Left  err -> do writeChan log ("gateway - received parse Error - " <> T.pack err
                                      <> " while decoding " <> TE.decodeUtf8 (BL.toStrict msg'))
                    pure (ParseError (T.pack err))


-- simple idea: send payloads from user/sys to connection
-- has to be complicated though
sendableLoop :: Connection -> GatewayHandle -> SendablesData -> Chan T.Text -> IO ()
sendableLoop conn ghandle sendablesData _log = sendSysLoop
  where
  sendSysLoop = do
      threadDelay $ round ((10^(6 :: Int)) * (62 / 120) :: Double)
      payload <- readChan (librarySendales sendablesData)
      sendTextData conn (encode payload)
   -- writeChan _log ("gateway - sending " <> TE.decodeUtf8 (BL.toStrict (encode payload)))
      usersending <- readIORef (startsendingUsers sendablesData)
      if not usersending
      then sendSysLoop
      else do act <- readIORef (gatewayHandleLastStatus ghandle)
              case act of Nothing -> pure ()
                          Just opts -> sendTextData conn (encode (UpdateStatus opts))
              sendUserLoop

  sendUserLoop = do
   -- send a ~120 events a min by delaying
      threadDelay $ round ((10^(6 :: Int)) * (62 / 120) :: Double)
   -- payload :: Either GatewaySendableInternal GatewaySendable
      payload <- race (readChan (gatewayHandleUserSendables ghandle)) (readChan (librarySendales sendablesData))
      sendTextData conn (either encode encode payload)
   -- writeChan _log ("gateway - sending " <> TE.decodeUtf8 (BL.toStrict (either encode encode payload)))
      sendUserLoop
