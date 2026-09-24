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
    public var activeConnectionCount: Int { relays.count }

    /// Stops accepting and aborts every open tunnel.
    public func stop() async {
        try? await listener.close()
        relays.cancelAll()
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
        guard relays.reserve() else {
            fail(.generalFailure, channel: channel)
            return
        }
        let backend = backend
        let relays = relays
        let handler = UncheckedSendableBox(self)
        relays.start { [pendingAtOpen = pending] in
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
            await TunnelRelay.run(inbound, exit)
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

/// Tracks running tunnel tasks so a stop can abort them, with a cap on how
/// many run at once.
final class TunnelTaskSet: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var reserved = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cancelled = false

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int { lock.withLock { reserved } }

    /// Claims a slot for a task about to `start`.
    func reserve() -> Bool {
        lock.withLock {
            guard !cancelled, reserved < limit else { return false }
            reserved += 1
            return true
        }
    }

    /// Runs `body` in a reserved slot; the slot frees when it returns.
    func start(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        lock.lock()
        let task = Task { [weak self] in
            await body()
            self?.finish(id)
        }
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        tasks[id] = task
        lock.unlock()
    }

    private func finish(_ id: UUID) {
        lock.withLock {
            tasks[id] = nil
            reserved = max(0, reserved - 1)
        }
    }

    func cancelAll() {
        let running: [Task<Void, Never>] = lock.withLock {
            cancelled = true
            let running = Array(tasks.values)
            tasks.removeAll()
            return running
        }
        for task in running { task.cancel() }
    }
}

struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
