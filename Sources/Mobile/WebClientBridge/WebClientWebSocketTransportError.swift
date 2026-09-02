/// Errors raised before a browser connection is admitted to mobile RPC
/// machinery.
///
/// Associated strings are safe to return in a WebSocket close reason and never
/// contain the presented bearer token.
nonisolated enum WebClientWebSocketTransportError: Error, Equatable, Sendable {
    case timedOut
    case protocolMismatch(expected: String, received: String?)
    case invalidHello
    case invalidToken
    case notReady
    case closed
    case receiveFailed(String)
    case sendFailed(String)
}
