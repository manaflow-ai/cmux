enum SocketConnectCompletion {
    case connected
    case pending(Int32)
    case failed(Int32)
}
