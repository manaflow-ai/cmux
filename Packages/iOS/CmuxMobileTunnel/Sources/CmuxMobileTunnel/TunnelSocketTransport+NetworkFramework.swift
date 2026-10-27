#if canImport(Network)
import NIOCore
import NIOTransportServices
import Network

/// Network.framework sockets through NIOTransportServices (see
/// `TunnelSocketTransport`).
extension TunnelSocketTransport {
    /// An event loop of the group this transport's channels run on.
    public func nextEventLoop() -> any EventLoop {
        NIOTSEventLoopGroup.singleton.next()
    }

    /// Binds a listener on `127.0.0.1:port` (`0` picks a free port). Accepted
    /// channels allow remote half-close and start with `autoRead` off.
    public func listenOnLoopback(
        port: Int,
        childChannelInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .childChannelInitializer(childChannelInitializer)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .bind(host: "127.0.0.1", port: port)
            .get()
    }

    /// Opens a TCP connection to `host:port` on `eventLoop` (any of the
    /// transport's loops when nil). `relay` allows remote half-close and turns
    /// `autoRead` off, for a stream a `NIOChannelByteStream` will own.
    public func connect(
        host: String,
        port: Int,
        timeout: TimeAmount,
        eventLoop: (any EventLoop)? = nil,
        relay: Bool,
        channelInitializer: (@Sendable (any Channel) -> EventLoopFuture<Void>)? = nil
    ) async throws -> any Channel {
        var bootstrap = NIOTSConnectionBootstrap(group: eventLoop ?? NIOTSEventLoopGroup.singleton.next())
            .connectTimeout(timeout)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
        if relay {
            bootstrap = bootstrap
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelOption(ChannelOptions.autoRead, value: false)
        }
        if let channelInitializer {
            bootstrap = bootstrap.channelInitializer(channelInitializer)
        }
        return try await bootstrap.connect(host: host, port: port).get()
    }

    /// The tunnel failure a Network.framework connect error means, or nil when
    /// it is not one.
    func openError(_ error: any Error) -> TunnelOpenError? {
        guard let error = error as? NWError else { return nil }
        switch error {
        case .posix(let code): return TunnelOpenError(connectFailure: code)
        case .dns: return .hostUnreachable
        default: return nil
        }
    }
}
#endif
