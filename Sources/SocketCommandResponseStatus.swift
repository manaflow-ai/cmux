enum SocketCommandResponseStatus: String, Sendable {
    case ok
    case error
    case noResponse = "no-response"
}
