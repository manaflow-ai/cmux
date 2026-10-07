import CmuxLink
import CmuxMobileWire

/// The tunnel family on this Mac (c14-web.md section 3): register its
/// handlers into the host's `MobileChannelHandlers`. One instance per
/// `MobileHost`, so every session shares the stream caps.
public struct MobileTunnels: Sendable {
    public let configuration: MobileTunnelConfiguration
    public let ports: any MobileTunnelPortDirectory
    private let connector: any MobileLoopbackConnector
    private let limiter: TunnelStreamLimiter

    public init(configuration: MobileTunnelConfiguration = MobileTunnelConfiguration(), ports: any MobileTunnelPortDirectory,
                connector: any MobileLoopbackConnector = NetworkLoopbackConnector()) {
        self.configuration = configuration
        self.ports = ports
        self.connector = connector
        limiter = TunnelStreamLimiter(perDevice: configuration.maxStreamsPerDevice, total: configuration.maxStreamsTotal)
    }

    /// `handlers` plus `tcp.forward` and `tunnel.ports`.
    public func registering(into handlers: MobileChannelHandlers = MobileChannelHandlers()) -> MobileChannelHandlers {
        var channels = handlers.channels
        var reads = handlers.reads
        channels[.tcpForward] = TcpForwardHandler(configuration: configuration, ports: ports, connector: connector,
                                                  limiter: limiter)
        reads["tunnel.ports"] = TunnelPortsReadHandler(policy: MobileTunnelPolicy(configuration: configuration), ports: ports)
        return MobileChannelHandlers(channels: channels, reads: reads)
    }
}
