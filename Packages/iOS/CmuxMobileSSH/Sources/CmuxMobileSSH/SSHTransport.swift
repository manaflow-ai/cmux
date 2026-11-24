import NIOCore
#if canImport(Network)
import NIOTransportServices
#else
import NIOPosix
#endif

/// The sockets under SSH: Network.framework (NIOTransportServices) on Apple platforms, plain POSIX
/// sockets (NIOPosix) elsewhere, so the package's tests run on Linux.
struct SSHTransport {
    package init() {}
    /// An event loop for a new connection.
    static func nextEventLoop() -> any EventLoop {
        #if canImport(Network)
        NIOTSEventLoopGroup.singleton.next()
        #else
        MultiThreadedEventLoopGroup.singleton.next()
        #endif
    }

    /// Connects to `host:port` on `eventLoop`, running `initializer` on the channel before any inbound byte.
    static func connect(
        eventLoop: any EventLoop,
        host: String,
        port: Int,
        timeout: TimeAmount,
        initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        #if canImport(Network)
        try await NIOTSConnectionBootstrap(group: eventLoop)
            .connectTimeout(timeout)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .channelInitializer(initializer)
            .connect(host: host, port: port)
            .get()
        #else
        try await ClientBootstrap(group: eventLoop)
            .connectTimeout(timeout)
            .channelInitializer(initializer)
            .connect(host: host, port: port)
            .get()
        #endif
    }

    /// Binds a loopback listener whose accepted channels start paused (`autoRead` off) and allow
    /// half-closure.
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
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer(childInitializer)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .bind(host: host, port: port)
            .get()
        #endif
    }
}
