import CmuxMobileWire

/// The pluggable services of a host: channel handlers by kind and read
/// handlers by op. `rpc` and `terminal` are served by the core and cannot be
/// replaced here.
public struct MobileChannelHandlers: Sendable {
    public var channels: [ChannelKind: any MobileChannelHandler]
    public var reads: [String: any MobileReadHandler]

    public init(channels: [ChannelKind: any MobileChannelHandler] = [:], reads: [String: any MobileReadHandler] = [:]) {
        self.channels = channels.filter { $0.key != .rpc && $0.key != .terminal }
        self.reads = reads
    }
}
