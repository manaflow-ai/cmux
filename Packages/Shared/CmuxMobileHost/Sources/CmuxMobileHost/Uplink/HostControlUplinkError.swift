/// Why the uplink stopped before or during its handshake.
public struct HostControlUplinkError: Error, Hashable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
