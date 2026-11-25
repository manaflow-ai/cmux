import Foundation
import NIOCore
import NIOTransportServices

/// A SOCKS5 proxy on the phone's loopback whose connections are opened by a
/// `SocksConnectBackend` at its exit point (an SSH server, a paired Mac).
///
/// Implements RFC 1928 with the no-authentication method and `CONNECT`
/// only (IPv4, IPv6, and domain-name address types). The host is passed to
/// the backend as sent, so domain names resolve at the exit.
public final class SocksProxyServer: Sendable {
    /// The bound loopback port.
    public let port: Int
    private let listener: any Channel
    private let relays: TunnelTaskSet

    private init(port: Int, listener: any Channel, relays: TunnelTaskSet) {
        self.port = port
        self.listener = listener
        self.relays = relays
    }

    /// Starts the proxy on `127.0.0.1:<port>` (`0` picks a free port).
    /// `onConnect` observes each accepted request (host as sent, port).
    /// Beyond `maximumConnections` concurrent tunnels, requests are refused
    /// with a general failure instead of queueing unbounded.
    public static func start(
        backend: any SocksConnectBackend,
        port: Int = 0,
        maximumConnections: Int = 256,
        onConnect: (@Sendable (String, Int) -> Void)? = nil
    ) async throws -> SocksProxyServer {
        let relays = TunnelTaskSet(limit: maximumConnections)
        let listener = try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .childChannelInitializer { inbound in
                inbound.eventLoop.makeCompletedFuture {
                    try inbound.pipeline.syncOperations.addHandler(
                        SocksHandshakeHandler(backend: backend, relays: relays, onConnect: onConnect)
                    )
                }
            }
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .bind(host: "127.0.0.1", port: port)
            .get()
        guard let bound = listener.localAddress?.port else {
            try? await listener.close()
            throw TunnelOpenError.generalFailure
        }
        return SocksProxyServer(port: bound, listener: listener, relays: relays)
    }

    /// Whether the listener still accepts (iOS can invalidate listeners of a
    /// suspended app).
    public var isListening: Bool { listener.isActive }

    /// Number of tunnels currently relaying.
    public var activeConnectionCount: Int {
        get async { await relays.count }
    }

    /// Stops accepting and aborts every open tunnel.
    public func stop() async {
        try? await listener.close()
        await relays.cancelAll()
    }
}

/// Runs the SOCKS5 greeting and request on an accepted connection (which has
/// `autoRead` off), asks the backend for the tunnel, replies, and hands the
/// connection to a relay.
final class SocksHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State { case greeting, request, connecting, done }

    private let backend: any SocksConnectBackend
    private let relays: TunnelTaskSet
    private let onConnect: (@Sendable (String, Int) -> Void)?
    private var state = State.greeting
    private var pending: [UInt8] = []

    init(backend: any SocksConnectBackend, relays: TunnelTaskSet, onConnect: (@Sendable (String, Int) -> Void)?) {
        self.backend = backend
        self.relays = relays
        self.onConnect = onConnect
    }

    func channelActive(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readBytes(length: buffer.readableBytes) ?? []
        guard pending.count <= SocksParse.maximumMessageByteCount * 2 else {
            state = .done
            context.close(promise: nil)
            return
        }
        advance(context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        // Keep pulling until the request is complete.
        if state == .greeting || state == .request { context.read() }
    }

    private func advance(context: ChannelHandlerContext) {
        switch state {
        case .greeting:
            switch SocksParse.greeting(pending) {
            case .needMoreData:
                return
            case .greeting(let acceptsNoAuth, let consumed):
                pending.removeFirst(consumed)
                var reply = context.channel.allocator.buffer(capacity: 2)
                // 0xFF: no acceptable method (only no-auth is offered).
                reply.writeBytes([0x05, acceptsNoAuth ? 0x00 : 0xFF])
                guard acceptsNoAuth else {
                    state = .done
                    let channel = context.channel
                    context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in channel.close(promise: nil) }
                    return
                }
                context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
                state = .request
                advance(context: context)
            default:
                state = .done
                context.close(promise: nil)
            }
        case .request:
            switch SocksParse.request(pending) {
            case .needMoreData:
                return
            case .connect(let host, let port, let consumed):
                pending.removeFirst(consumed)
                state = .connecting
                open(host: host, port: port, context: context)
            case .reject(let code):
                fail(code, channel: context.channel)
            default:
                state = .done
                context.close(promise: nil)
            }
        case .connecting, .done:
            return
        }
    }

    private func open(host: String, port: Int, context: ChannelHandlerContext) {
        onConnect?(host, port)
        let channel = context.channel
        let backend = backend
        let relays = relays
        let handler = UncheckedSendableBox(self)
        let body: @Sendable () async -> Void = { [pendingAtOpen = pending] in
            let exit: any TunnelByteStream
            do {
                exit = try await backend.open(host: host, port: port)
            } catch {
                let reply = SocksReply.forOpenFailure(error)
                _ = try? await channel.eventLoop.submit { handler.value.fail(reply, channel: channel) }.get()
                return
            }
            // Reply, then swap the handshake handler for the byte adapter;
            // the success reply is queued ahead of any relayed byte.
            let inbound: NIOChannelByteStream
            do {
                inbound = try await channel.eventLoop.submit { () throws -> NIOChannelByteStream in
                    handler.value.state = .done
                    let reply = SocksReply.succeeded.message(allocator: channel.allocator)
                    channel.writeAndFlush(reply, promise: nil)
                    let stream = try NIOChannelByteStream.installSync(on: channel, leftover: pendingAtOpen)
                    channel.pipeline.removeHandler(handler.value, promise: nil)
                    return stream
                }.get()
            } catch {
                await exit.close()
                try? await channel.close().get()
                return
            }
            await TunnelRelay(inbound, exit).run()
        }
        // Over the connection cap (or after `stop`), refuse instead of queueing.
        Task {
            if await !relays.start(body) {
                _ = try? await channel.eventLoop.submit { handler.value.fail(.generalFailure, channel: channel) }.get()
            }
        }
    }

    private func fail(_ code: SocksReply, channel: any Channel) {
        state = .done
        let reply = code.message(allocator: channel.allocator)
        channel.writeAndFlush(reply).whenComplete { _ in channel.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
