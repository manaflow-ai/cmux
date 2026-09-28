import Foundation
import NIOCore
import NIOTransportServices

/// A SOCKS5 proxy on the phone's loopback whose every connection leaves from
/// the SSH server (`ssh -D`).
///
/// Each `CONNECT` becomes a `direct-tcpip` channel to the requested
/// host and port, and a domain-name address is resolved by the server. A
/// browser using this proxy therefore sees the server's network: its
/// `localhost`, every port on it, and names only the server can resolve,
/// with the page's own origin unchanged.
///
/// Implements RFC 1928 with the no-authentication method and the `CONNECT`
/// command only (IPv4, IPv6, and domain-name address types).
public final class SSHSocksProxy: Sendable {
    /// The bound loopback port.
    public let port: Int
    private let listener: any Channel

    private init(port: Int, listener: any Channel) {
        self.port = port
        self.listener = listener
    }

    /// Starts the proxy on `127.0.0.1:<port>` (`0` picks a free port).
    /// `onConnect` observes each accepted request (host as sent, port).
    public static func start(
        over connection: SSHConnection,
        port: Int = 0,
        onConnect: (@Sendable (String, Int) -> Void)? = nil
    ) async throws -> SSHSocksProxy {
        let listener = try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .childChannelInitializer { inbound in
                inbound.pipeline.addHandler(SSHSocksHandshakeHandler { host, targetPort, inbound, remoteGlue, reply in
                    onConnect?(host, targetPort)
                    let promise = inbound.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        _ = try await connection.openDirectTCPIP(host: host, port: targetPort) { child in
                            child.pipeline.addHandlers([
                                SSHSocksSuccessReplier(inbound: inbound, reply: reply),
                                SSHChannelDataUnwrapper(),
                                remoteGlue,
                            ])
                        }
                    }
                    return promise.futureResult
                })
            }
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .bind(host: "127.0.0.1", port: port)
            .get()
        guard let bound = listener.localAddress?.port else {
            try? await listener.close()
            throw SSHConnectionError.channelOpenFailed("SOCKS listener has no port")
        }
        return SSHSocksProxy(port: bound, listener: listener)
    }

    /// Stops accepting connections. Open tunnels end with the SSH connection.
    public func stop() async {
        try? await listener.close()
    }
}

/// Sends the SOCKS success reply once the server confirms the
/// `direct-tcpip` channel (it becomes active), so a refused connect never
/// reports success. Queued on the client's loop ahead of any relayed byte.
final class SSHSocksSuccessReplier: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    private let inbound: any Channel
    private let reply: ByteBuffer

    init(inbound: any Channel, reply: ByteBuffer) {
        self.inbound = inbound
        self.reply = reply
    }

    func channelActive(context: ChannelHandlerContext) {
        inbound.writeAndFlush(reply, promise: nil)
        context.fireChannelActive()
    }
}

/// SOCKS5 reply codes (RFC 1928 §6).
enum SSHSocksReply: UInt8 {
    case succeeded = 0x00
    case generalFailure = 0x01
    case notAllowed = 0x02
    case hostUnreachable = 0x04
    case connectionRefused = 0x05
    case commandNotSupported = 0x07
    case addressTypeNotSupported = 0x08

    /// The reply for a rejected `direct-tcpip` open. OpenSSH reports every
    /// connect failure (refused, unreachable, unresolvable) as
    /// `SSH_OPEN_CONNECT_FAILED` (2) and a forbidden forward as
    /// `SSH_OPEN_ADMINISTRATIVELY_PROHIBITED` (1).
    static func forChannelOpenFailure(_ error: any Error) -> SSHSocksReply {
        let text = String(describing: error)
        if text.contains("Reason: 1 ") || text.hasSuffix("Reason: 1") { return .notAllowed }
        if text.contains("Reason: 2 ") || text.hasSuffix("Reason: 2") { return .connectionRefused }
        return .hostUnreachable
    }

    func message(allocator: ByteBufferAllocator) -> ByteBuffer {
        // VER, REP, RSV, ATYP=IPv4, BND.ADDR 0.0.0.0, BND.PORT 0.
        var buffer = allocator.buffer(capacity: 10)
        buffer.writeBytes([0x05, rawValue, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        return buffer
    }
}

/// A parsed SOCKS5 request, or why it cannot be served.
enum SSHSocksParse: Equatable {
    case needMoreData
    case greeting(acceptsNoAuth: Bool, consumed: Int)
    case connect(host: String, port: Int, consumed: Int)
    case reject(SSHSocksReply)
    case malformed

    static func greeting(_ bytes: [UInt8]) -> SSHSocksParse {
        guard bytes.count >= 2 else { return .needMoreData }
        guard bytes[0] == 0x05 else { return .malformed }
        let count = Int(bytes[1])
        guard bytes.count >= 2 + count else { return .needMoreData }
        return .greeting(acceptsNoAuth: bytes[2..<(2 + count)].contains(0x00), consumed: 2 + count)
    }

    static func request(_ bytes: [UInt8]) -> SSHSocksParse {
        guard bytes.count >= 4 else { return .needMoreData }
        guard bytes[0] == 0x05 else { return .malformed }
        let host: String
        let addressEnd: Int
        switch bytes[3] {
        case 0x01:
            addressEnd = 4 + 4
            guard bytes.count >= addressEnd + 2 else { return .needMoreData }
            host = bytes[4..<addressEnd].map(String.init).joined(separator: ".")
        case 0x04:
            addressEnd = 4 + 16
            guard bytes.count >= addressEnd + 2 else { return .needMoreData }
            host = stride(from: 4, to: addressEnd, by: 2)
                .map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
                .joined(separator: ":")
        case 0x03:
            guard bytes.count >= 5 else { return .needMoreData }
            addressEnd = 5 + Int(bytes[4])
            guard bytes.count >= addressEnd + 2 else { return .needMoreData }
            host = String(decoding: bytes[5..<addressEnd], as: UTF8.self)
        default:
            return .reject(.addressTypeNotSupported)
        }
        // Only CONNECT; BIND and UDP ASSOCIATE are not offered.
        guard bytes[1] == 0x01 else { return .reject(.commandNotSupported) }
        let port = Int(bytes[addressEnd]) << 8 | Int(bytes[addressEnd + 1])
        guard !host.isEmpty, port > 0 else { return .reject(.hostUnreachable) }
        return .connect(host: host, port: port, consumed: addressEnd + 2)
    }
}

/// Runs the SOCKS5 greeting and request on an accepted connection, then
/// hands the connection to the tunnel glue and removes itself.
final class SSHSocksHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// Opens the tunnel for `host:port`. It must write `reply` (the success
    /// reply) on the inbound channel before the remote glue starts relaying,
    /// and fail when the server refuses the channel.
    typealias Connect = @Sendable (
        _ host: String, _ port: Int, _ inbound: any Channel, _ remoteGlue: SSHGlueHandler, _ reply: ByteBuffer
    ) -> EventLoopFuture<Void>

    private enum State { case greeting, request, connecting, done }

    private let connect: Connect
    private var state = State.greeting
    private var pending: [UInt8] = []

    init(connect: @escaping Connect) {
        self.connect = connect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard state != .done else {
            context.fireChannelRead(data)
            return
        }
        pending += buffer.readBytes(length: buffer.readableBytes) ?? []
        advance(context: context)
    }

    private func advance(context: ChannelHandlerContext) {
        switch state {
        case .greeting:
            switch SSHSocksParse.greeting(pending) {
            case .needMoreData:
                return
            case .greeting(let acceptsNoAuth, let consumed):
                pending.removeFirst(consumed)
                var reply = context.channel.allocator.buffer(capacity: 2)
                // 0xFF: no acceptable method (we only offer no-auth).
                reply.writeBytes([0x05, acceptsNoAuth ? 0x00 : 0xFF])
                guard acceptsNoAuth else {
                    let box = UncheckedBox(context)
                    context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in box.value.close(promise: nil) }
                    state = .done
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
            switch SSHSocksParse.request(pending) {
            case .needMoreData:
                return
            case .connect(let host, let port, let consumed):
                pending.removeFirst(consumed)
                state = .connecting
                open(host: host, port: port, context: context)
            case .reject(let code):
                fail(code, context: context)
            default:
                state = .done
                context.close(promise: nil)
            }
        case .connecting, .done:
            return
        }
    }

    private func open(host: String, port: Int, context: ChannelHandlerContext) {
        // Hold further client bytes until the tunnel exists.
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
        let (local, remote) = SSHGlueHandler.matchedPair()
        let reply = SSHSocksReply.succeeded.message(allocator: context.channel.allocator)
        let box = UncheckedBox(context)
        let channel = context.channel
        // The local glue sits after this handler, so it relays only what
        // this handler passes on once the tunnel is up.
        context.pipeline.addHandler(local).flatMap {
            self.connect(host, port, channel, remote, reply)
        }.whenComplete { result in
            let context = box.value
            switch result {
            case .success:
                self.state = .done
                let leftover = self.pending
                self.pending = []
                if !leftover.isEmpty {
                    var buffer = context.channel.allocator.buffer(capacity: leftover.count)
                    buffer.writeBytes(leftover)
                    context.fireChannelRead(self.wrapInboundOut(buffer))
                    context.fireChannelReadComplete()
                }
                context.pipeline.removeHandler(self, promise: nil)
                context.channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in
                    box.value.read()
                }
            case .failure(let error):
                self.fail(SSHSocksReply.forChannelOpenFailure(error), context: context)
            }
        }
    }

    private func fail(_ code: SSHSocksReply, context: ChannelHandlerContext) {
        state = .done
        let reply = code.message(allocator: context.channel.allocator)
        let box = UncheckedBox(context)
        context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in box.value.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
