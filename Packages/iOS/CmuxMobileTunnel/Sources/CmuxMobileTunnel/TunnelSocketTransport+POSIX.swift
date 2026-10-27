#if !canImport(Network)
import Foundation
import NIOCore
import NIOPosix

/// NIOPosix sockets, for platforms without Network.framework (see
/// `TunnelSocketTransport`).
extension TunnelSocketTransport {
    /// An event loop of the group this transport's channels run on.
    public func nextEventLoop() -> any EventLoop {
        MultiThreadedEventLoopGroup.singleton.next()
    }

    /// Binds a listener on `127.0.0.1:port` (`0` picks a free port). Accepted
    /// channels allow remote half-close and start with `autoRead` off.
    public func listenOnLoopback(
        port: Int,
        childChannelInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
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
        var bootstrap = ClientBootstrap(group: eventLoop ?? MultiThreadedEventLoopGroup.singleton.next())
            .connectTimeout(timeout)
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

    /// The tunnel failure a NIOPosix connect error means, or nil when it is
    /// not one. A failed resolution or every address failing arrives as a
    /// `NIOConnectionError`; the first address's `errno` stands for the rest.
    func openError(_ error: any Error) -> TunnelOpenError? {
        if let error = error as? IOError {
            return POSIXErrorCode(rawValue: error.errnoCode).map(TunnelOpenError.init(connectFailure:))
        }
        guard let error = error as? NIOConnectionError else { return nil }
        if let failure = error.connectionErrors.first {
            return openError(failure.error) ?? .generalFailure
        }
        if error.dnsAError != nil || error.dnsAAAAError != nil {
            return .hostUnreachable
        }
        return nil
    }
}
#endif
