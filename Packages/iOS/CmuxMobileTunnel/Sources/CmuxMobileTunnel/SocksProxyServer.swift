import Foundation
import NIOCore
import NIOTransportServices

/// A SOCKS5 proxy on the phone's loopback whose connections are opened by a
/// `SocksConnectBackend` at its exit point (an SSH server, a paired Mac).
///
/// Implements RFC 1928 with `CONNECT` only (IPv4, IPv6, and domain-name
/// address types). By default it offers no authentication; callers that bind
/// on a shared loopback must pass a ``SocksCredential`` to require RFC 1929
/// username/password authentication. The host is passed to the backend as
/// sent, so domain names resolve at the exit.
public final class SocksProxyServer: Sendable {
    /// The bound loopback port.
    public let port: Int
    private let listener: any Channel
    private let relays: TunnelTaskSet
    private let lifecycle: SocksProxyLifecycle

    private init(port: Int, listener: any Channel, relays: TunnelTaskSet, lifecycle: SocksProxyLifecycle) {
        self.port = port
        self.listener = listener
        self.relays = relays
        self.lifecycle = lifecycle
    }

    /// Starts the proxy on `127.0.0.1:<port>` (`0` picks a free port).
    /// `onConnect` observes each accepted request (host as sent, port).
    /// Beyond `maximumConnections` concurrent tunnels, requests are refused
    /// with a general failure instead of queueing unbounded.
    public static func start(
        backend: any SocksConnectBackend,
        port: Int = 0,
        maximumConnections: Int = 256,
        credential: SocksCredential? = nil,
        onConnect: (@Sendable (String, Int) -> Void)? = nil
    ) async throws -> SocksProxyServer {
        let relays = TunnelTaskSet(limit: maximumConnections)
        let lifecycle = SocksProxyLifecycle()
        let listener = try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .childChannelInitializer { inbound in
                guard lifecycle.register(inbound) else {
                    return inbound.eventLoop.makeCompletedFuture {
                        inbound.close(promise: nil)
                    }
                }
                return inbound.eventLoop.makeCompletedFuture {
                    try inbound.pipeline.syncOperations.addHandler(
                        SocksHandshakeHandler(backend: backend, relays: relays, lifecycle: lifecycle,
                                             credential: credential, onConnect: onConnect)
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
        return SocksProxyServer(port: bound, listener: listener, relays: relays, lifecycle: lifecycle)
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
        await lifecycle.stop()
        try? await listener.close()
        await relays.cancelAll()
    }
}

/// Shared lifecycle state for a proxy listener and all of its child channels.
///
/// The listener can be closed while an accepted channel is still in the
/// SOCKS handshake. Keep those channels in the same stop domain so stopping a
/// route cannot leave a handshake alive long enough to open a new backend
/// connection. This is deliberately lock-based: child-channel initialization
/// happens on an NIO event loop while `stop()` runs from an async caller.
final class SocksProxyLifecycle: @unchecked Sendable {
    // lint:allow: the NIO event loop and async stop caller share this small lifecycle gate.
    private let lock = NSLock()
    private var stopped = false
    private var channels: [ObjectIdentifier: any Channel] = [:]

    /// Registers an accepted child. Returns false when stop has already begun.
    @discardableResult
    func register(_ channel: any Channel) -> Bool {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            channel.close(promise: nil)
            return false
        }
        channels[ObjectIdentifier(channel)] = channel
        lock.unlock()
        return true
    }

    func unregister(_ channel: any Channel) {
        lock.lock()
        channels[ObjectIdentifier(channel)] = nil
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Marks the listener stopped and closes every handshake channel that was
    /// accepted before the stop. New child channels are rejected by register.
    func stop() async {
        let channels = takeStopChannels()

        for channel in channels {
            try? await channel.close().get()
        }
    }

    private func takeStopChannels() -> [any Channel] {
        lock.lock()
        stopped = true
        let channels = Array(self.channels.values)
        self.channels.removeAll()
        lock.unlock()
        return channels
    }
}

/// Runs the SOCKS5 greeting and request on an accepted connection (which has
/// `autoRead` off), asks the backend for the tunnel, replies, and hands the
/// connection to a relay.
final class SocksHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State { case greeting, authentication, request, connecting, done }

    private let backend: any SocksConnectBackend
    private let relays: TunnelTaskSet
    private let lifecycle: SocksProxyLifecycle
    private let credential: SocksCredential?
    private let onConnect: (@Sendable (String, Int) -> Void)?
    private var state = State.greeting
    private var pending: [UInt8] = []

    init(backend: any SocksConnectBackend, relays: TunnelTaskSet, lifecycle: SocksProxyLifecycle,
         credential: SocksCredential?,
         onConnect: (@Sendable (String, Int) -> Void)?) {
        self.backend = backend
        self.relays = relays
        self.lifecycle = lifecycle
        self.credential = credential
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
        if state == .greeting || state == .authentication || state == .request { context.read() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lifecycle.unregister(context.channel)
        context.fireChannelInactive()
    }

    private func advance(context: ChannelHandlerContext) {
        switch state {
        case .greeting:
            switch SocksParse.greeting(pending) {
            case .needMoreData:
                return
            case .greeting(let acceptsNoAuth, let consumed):
                let offeredMethods = pendingGreetingMethods(consumed: consumed)
                pending.removeFirst(consumed)
                var reply = context.channel.allocator.buffer(capacity: 2)
                // A credentialed route must not silently downgrade to
                // unauthenticated SOCKS. Select RFC 1929 (0x02) when the
                // client offered it; no-auth routes retain the old 0x00 path.
                let method: UInt8
                if credential != nil {
                    let offeredUserPassword = offeredMethods.contains(0x02)
                    method = offeredUserPassword ? 0x02 : 0xFF
                    if offeredUserPassword { state = .authentication }
                } else {
                    method = acceptsNoAuth ? 0x00 : 0xFF
                    if method == 0x00 { state = .request }
                }
                reply.writeBytes([0x05, method])
                guard method != 0xFF else {
                    state = .done
                    let channel = context.channel
                    context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in channel.close(promise: nil) }
                    return
                }
                context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
                advance(context: context)
            default:
                state = .done
                context.close(promise: nil)
            }
        case .authentication:
            switch SocksParse.authentication(pending) {
            case .needMoreData:
                return
            case .authentication(let username, let password, let consumed):
                pending.removeFirst(consumed)
                let accepted = credential?.matches(username: username, password: password) == true
                var reply = context.channel.allocator.buffer(capacity: 2)
                reply.writeBytes([0x01, accepted ? 0x00 : 0x01])
                guard accepted else {
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
        let lifecycle = lifecycle
        let handler = UncheckedSendableBox(self)
        let body: @Sendable () async -> Void = { [pendingAtOpen = pending] in
            guard !lifecycle.isStopped else {
                try? await channel.close().get()
                return
            }
            let exit: any TunnelByteStream
            do {
                exit = try await backend.open(host: host, port: port)
            } catch {
                let reply = SocksReply.forOpenFailure(error)
                _ = try? await channel.eventLoop.submit { handler.value.fail(reply, channel: channel) }.get()
                return
            }
            guard !lifecycle.isStopped else {
                await exit.close()
                try? await channel.close().get()
                return
            }
            // Reply, then swap the handshake handler for the byte adapter;
            // the success reply is queued ahead of any relayed byte.
            let inbound: NIOChannelByteStream
            do {
                inbound = try await channel.eventLoop.submit { () throws -> NIOChannelByteStream in
                    guard !lifecycle.isStopped, channel.isActive else {
                        throw TunnelOpenError.unavailable
                    }
                    handler.value.state = .done
                    let reply = SocksReply.succeeded.message(allocator: channel.allocator)
                    channel.writeAndFlush(reply, promise: nil)
                    let stream = try NIOChannelByteStream.installSync(on: channel, leftover: pendingAtOpen)
                    lifecycle.unregister(channel)
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

    /// `SocksParse.greeting` returns only whether no-auth was offered. Keep
    /// the raw method list locally so a credentialed listener can select 0x02
    /// without changing the public parse result used by existing callers.
    private func pendingGreetingMethods(consumed: Int) -> ArraySlice<UInt8> {
        guard consumed >= 2, pending.count >= consumed else { return [] }
        return pending[2..<consumed]
    }
}

struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
