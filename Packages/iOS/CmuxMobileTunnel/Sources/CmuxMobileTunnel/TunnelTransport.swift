import Foundation
import NIOCore
#if canImport(Network)
import NIOTransportServices
#else
import NIOPosix
#endif

/// The sockets under the tunnel: Network.framework (NIOTransportServices) on Apple platforms, plain
/// POSIX sockets (NIOPosix) elsewhere, so the plumbing's tests run on Linux.
struct TunnelTransport {
    package init() {}
    /// Binds a loopback listener on `host:port` whose accepted channels run `childInitializer`, with
    /// half-closure allowed and auto-read off.
    static func listen(
        host: String,
        port: Int,
        childInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        #if canImport(Network)
        try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .childChannelInitializer(childInitializer)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .bind(host: host, port: port)
            .get()
        #else
        // autoRead stays on here: a NIOPosix channel with it off drops bytes still unread when the peer
        // half-closes (EPOLLRDHUP is handled before a pulled read), which Network.framework does not.
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer(childInitializer)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .bind(host: host, port: port)
            .get()
        #endif
    }

    /// Connects out to `host:port`, half-closure allowed and auto-read off.
    static func connect(host: String, port: Int, timeout: TimeAmount) async throws -> any Channel {
        #if canImport(Network)
        try await NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelOption(ChannelOptions.autoRead, value: false)
            .connect(host: host, port: port)
            .get()
        #else
        try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelOption(ChannelOptions.autoRead, value: true)
            .connect(host: host, port: port)
            .get()
        #endif
    }
}
