/// The socket closed with a WebSocket close code (4002 version, 4401 revoked or expired, 4000 replaced).
public struct ControlPlaneCloseError: Error, Hashable, Sendable {
    public var code: Int
    public var reason: String
    public init(code: Int, reason: String = "") {
        self.code = code
        self.reason = reason
    }

    /// Codes after which reconnecting cannot help: a version mismatch or a revoked install.
    public var isTerminal: Bool { code == 4002 || code == 4401 || code == 4403 }
}
