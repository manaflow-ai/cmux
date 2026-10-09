/// The socket closed with a WebSocket close code (4002 version, 4401 revoked or expired, 4000 replaced).
public struct ControlPlaneCloseError: Error, Hashable, Sendable {
    public var code: Int
    public var reason: String
    public init(code: Int, reason: String = "") {
        self.code = code
        self.reason = reason
    }

    /// Codes after which reconnecting cannot help: a version mismatch, a revoked install or lost
    /// access. An expired token (4401 "token expired") is not terminal: reconnect with a fresh one.
    public var isTerminal: Bool {
        switch code {
        case 4002, 4403: true
        case 4401: reason != "token expired"
        default: false
        }
    }
}
