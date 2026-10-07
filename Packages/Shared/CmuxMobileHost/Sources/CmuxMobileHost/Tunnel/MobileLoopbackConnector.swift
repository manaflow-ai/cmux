/// Opens TCP connections to this Mac's loopback only.
public protocol MobileLoopbackConnector: Sendable {
    /// Connects to `127.0.0.1:port`, then `[::1]:port` when refused, within `timeout`.
    func connect(port: UInt16, timeout: Duration) async throws -> any MobileLoopbackSocket
}
