/// `channel.opened` params of a `tcp.forward` channel.
public struct TcpForwardOpenedParams: Hashable, Sendable, Codable {
    public var port: UInt16
    public var source: TunnelPortSource

    public init(port: UInt16, source: TunnelPortSource) {
        self.port = port
        self.source = source
    }
}
