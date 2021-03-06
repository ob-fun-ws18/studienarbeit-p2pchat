{-|
Module      : P2PChat.Socket.Client
Description : Defines Client Implementation
Copyright   : (c) Chris Brammer, 2019
                  Wolfgang Gabler, 2019
-}

module P2PChat.Socket.Client (
  startSocketClient
) where

import P2PChat.Common
import P2PChat.Socket

import Data.Aeson as A

import Data.Maybe
import System.IO
import System.Timeout
import Network.Socket
import Control.Concurrent
import Control.Monad
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL

-- | Starts the client socket and tries to connect to the host
startSocketClient :: String  -- ^ Host to connect to (e.g "127.0.0.1")
                  -> Int  -- ^ Port to connect to
                  -> Global  -- ^ Global State
                  -> Channels  -- ^ Communication Channels
                  -> IO (Maybe ThreadId)  -- ^ Main ThreadId of the client
startSocketClient host port glob chans = do
  addrInfo <- getAddrInfo Nothing (Just host) (Just $ show port)
  let serverAddr = head addrInfo
  sock <- socket (addrFamily serverAddr) Stream defaultProtocol
  connect sock (addrAddress serverAddr)
  hdl <- socketToHandle sock ReadWriteMode
  hSetBuffering hdl NoBuffering
  success <- handshake hdl (myUserName glob) (myUUID glob) (myHostPort glob)
  if success then do
    id <- forkIO $ runClientSock glob chans hdl
    return $ Just id
  else
    return Nothing

-- | Send the handshake to the server
handshake :: Handle  -- ^ Handle to the server
          -> String  -- ^ Username to register as
          -> String  -- ^ UUID of this client
          -> Int  -- ^ Port we are running on
          -> IO Bool -- ^ True if successfull
handshake hdl name uuid port = do
  B.hPutStrLn hdl (BL.toStrict (A.encode (jsonConnect name uuid port)))
  eof <- hIsEOF hdl
  if eof then
    return False
  else do
    input <- B.hGetLine hdl
    let json = A.decode (BL.fromStrict input) :: Maybe JsonMessage
    case json of
      Just j -> return $ isJsonOK j
      Nothing -> return False

-- | Main routine for the client
runClientSock :: Global -> Channels -> Handle -> IO()
runClientSock glob chans handle = do
  outputChan <- newChan :: IO (Chan JsonMessage)
  readId <- forkIO $ readClientSock handle (csock chans)
  outputId <- forkIO $ runSocketOutput handle outputChan
  loopClientSock glob chans handle outputChan
  hClose handle
  killThread readId
  killThread outputId

-- | Client loop, forwards events appropriately to channels
loopClientSock :: Global -> Channels -> Handle -> Chan JsonMessage -> IO()
loopClientSock glob chans handle chan = do
  event <- readChan (csock chans)
  case event of
    s@(SockHostConnect _ _) -> writeChan (cmain chans) s
    s@(SockHostDisconnect _ _) -> writeChan (cmain chans) s
    s@(SockMsgIn _ _) -> writeChan (cmain chans) s
    SockMsgOut msg -> writeChan chan (jsonMessageSend "" msg)
    s@SockClientDisconnect -> writeChan (cmain chans) s
  unless (isDisconnect event) $ loopClientSock glob chans handle chan

-- | Read loop for the client with timeout
readClientSock :: Handle -> Chan Event -> IO ()
readClientSock hdl chan = do
  input <- timeout 1000000 $ readHandle hdl
  case input of
    Just i ->
      case i of
        Just i -> do
          case jsonParse i of
            Just m -> handleInput chan m
            Nothing -> putStrLn "DEBUG: Client Reading unknown msg"
          readClientSock hdl chan
        Nothing -> writeChan chan SockClientDisconnect -- disconnect
    Nothing -> writeChan chan SockClientDisconnect -- timeout  

-- | Routine to handle input of the client. Parsing of Json Messages
handleInput :: Chan Event -> JsonMessage -> IO ()
handleInput chan msg = case msg of
  (JsonMessage "message" _ _ _ (Just (JsonPayloadMessage user m))) -> writeChan chan (SockMsgIn user m)
  (JsonMessage "clientConnected" _ (Just (JsonPayloadClientConnected m ms)) _ _) -> writeChan chan (SockHostConnect m ms)
  (JsonMessage "clientDisconnected" _ _ (Just (JsonPayloadClientDisconnected m ms)) _) -> writeChan chan (SockHostDisconnect m ms)
  _ -> return ()

-- | Socket output for the client, also sends heartbeat automatically
runSocketOutput :: Handle -> Chan JsonMessage -> IO ()
runSocketOutput hdl chan = do
  msg <- timeout 500000 $ readChan chan
  case msg of
    Just m -> B.hPutStrLn hdl $ BL.toStrict $ A.encode m
    Nothing -> B.hPutStrLn hdl $ BL.toStrict $ A.encode jsonHeartbeat
  runSocketOutput hdl chan  