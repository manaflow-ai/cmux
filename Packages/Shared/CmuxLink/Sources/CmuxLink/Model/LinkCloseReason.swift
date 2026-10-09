/// Why a link closed. `closed` is terminal.
public enum LinkCloseReason: Sendable, Hashable {
    /// This side called `close()`.
    case local
    /// The peer closed the session.
    case remote
    /// The peer refused this client.
    case unauthorized
    /// No carrier reached the peer within the reconnect budget, or the
    /// dialer did not come back within the host's resume window.
    case unreachable(attempts: Int)
    /// The peer sent a frame this side cannot accept.
    case protocolViolation(String)
}
