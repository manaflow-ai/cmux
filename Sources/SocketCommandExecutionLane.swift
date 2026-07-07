enum SocketCommandExecutionLane: String, Sendable {
    case mainActor = "main-actor"
    case socketWorker = "socket-worker"
}
