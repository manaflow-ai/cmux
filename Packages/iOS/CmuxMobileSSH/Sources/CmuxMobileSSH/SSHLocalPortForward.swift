import Foundation
import NIOCore
import NIOTransportServices

/// A listener on the phone's loopback that tunnels each accepted connection
/// through SSH to `targetHost:targetPort` as seen from the server (`ssh -L`).
///
/// The in-app browser loads `http://127.0.0.1:<localPort>` to reach a web
/// server that only listens on the remote machine's localhost (PRD D7).
public final class SSHLocalPortForward: Sendable {
    public let targetHost: String
    public let targetPort: Int
    /// The bound loopback port.
    public let localPort: Int
    private let listener: any Channel

    private init(targetHost: String, targetPort: Int, localPort: Int, listener: any Channel) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.localPort = localPort
        self.listener = listener
    }

    /// Starts forwarding. `localPort` 0 picks a free port.
    public static func start(
        over connection: SSHConnection,
        targetHost: String = "127.0.0.1",
        targetPort: Int,
        localPort: Int = 0
    ) async throws -> SSHLocalPortForward {
        let listener = try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .childChannelInitializer { inbound in
                let (local, remote) = SSHGlueHandler.matchedPair()
                return inbound.pipeline.addHandler(local).flatMap {
                    let promise = inbound.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        do {
                            _ = try await connection.openDirectTCPIP(host: targetHost, port: targetPort) { child in
                                child.pipeline.addHandlers([SSHChannelDataUnwrapper(), remote])
                            }
                            // Accepted sockets start paused so no bytes arrive before the
                            // tunnel exists; resume now that both ends are glued.
                            try await inbound.setOption(ChannelOptions.autoRead, value: true)
                            inbound.read()
                        } catch {
                            try? await inbound.close()
                        }
                    }
                    return promise.futureResult
                }
            }
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .bind(host: "127.0.0.1", port: localPort)
            .get()
        guard let port = listener.localAddress?.port else {
            try? await listener.close()
            throw SSHConnectionError.channelOpenFailed("forward listener has no port")
        }
        return SSHLocalPortForward(targetHost: targetHost, targetPort: targetPort, localPort: port, listener: listener)
    }

    /// Stops accepting new connections. Open tunnels end with the SSH connection.
    public func stop() async {
        try? await listener.close()
    }
}

/// Joins two channels so bytes read on one are written to the other, and
/// propagates end-of-stream and close. No cross-loop backpressure yet: a fast
/// producer can buffer in memory (acceptable for dev-server browsing).
final class SSHGlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: SSHGlueHandler?
    private var context: ChannelHandlerContext?

    static func matchedPair() -> (SSHGlueHandler, SSHGlueHandler) {
        let first = SSHGlueHandler()
        let second = SSHGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    // Partners live on different event loops (TCP listener child vs SSH
    // child); hop to the partner's loop before touching its context.
    private func onPartner(_ body: @escaping @Sendable (SSHGlueHandler, ChannelHandlerContext) -> Void) {
        guard let partner, let context = partner.context else { return }
        let box = UncheckedBox(partner)
        let ctx = UncheckedBox(context)
        if context.eventLoop.inEventLoop {
            body(partner, context)
        } else {
            context.eventLoop.execute { body(box.value, ctx.value) }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = UncheckedBox(data)
        onPartner { _, partnerContext in partnerContext.write(data.value, promise: nil) }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        onPartner { _, partnerContext in partnerContext.flush() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onPartner { _, partnerContext in partnerContext.close(promise: nil) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // Half-closure is not reliable across Network.framework and SSH
            // channels, so drain what is already queued and close fully. Writes
            // are ordered, so the empty write completes after all real data.
            onPartner { _, partnerContext in
                let drained = partnerContext.eventLoop.makePromise(of: Void.self)
                partnerContext.writeAndFlush(NIOAny(partnerContext.channel.allocator.buffer(capacity: 0)), promise: drained)
                drained.futureResult.whenComplete { _ in partnerContext.close(promise: nil) }
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
