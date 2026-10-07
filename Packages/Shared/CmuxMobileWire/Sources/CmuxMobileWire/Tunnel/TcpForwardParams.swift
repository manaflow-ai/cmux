/// `channel.open` params of kind `tcp.forward` (c14-web.md section 3.1).
/// The phone names only a port; the Mac connects to its own loopback.
public struct TcpForwardParams: Hashable, Sendable, Codable {
    public var port: UInt16

    public init(port: UInt16) {
        self.port = port
    }
}
