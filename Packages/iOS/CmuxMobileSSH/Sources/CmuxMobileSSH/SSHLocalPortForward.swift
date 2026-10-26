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
                // SSH child channels run on their parent connection's loop.
                let (local, remote) = SSHGlueHandler.matchedPair(
                    localLoop: inbound.eventLoop,
                    remoteLoop: connection.eventLoop
                )
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
///
/// Partners live on different event loops (the TCP listener child and the
/// SSH child). Each side's context is in a `NIOLoopBoundBox` bound to that
/// side's loop, so a side touches its partner's context only after hopping to
/// the partner's loop, and the box traps any access that did not.
final class SSHGlueHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// This side's context while it is in its pipeline.
    private let ownContext: NIOLoopBoundBox<ChannelHandlerContext?>
    /// The partner's `ownContext`.
    private let partnerContext: NIOLoopBoundBox<ChannelHandlerContext?>

    private init(
        ownContext: NIOLoopBoundBox<ChannelHandlerContext?>,
        partnerContext: NIOLoopBoundBox<ChannelHandlerContext?>
    ) {
        self.ownContext = ownContext
        self.partnerContext = partnerContext
    }

    /// Two glued handlers: `local` goes in a channel on `localLoop`, `remote`
    /// in one on `remoteLoop`.
    static func matchedPair(
        localLoop: any EventLoop,
        remoteLoop: any EventLoop
    ) -> (local: SSHGlueHandler, remote: SSHGlueHandler) {
        let local = NIOLoopBoundBox.makeEmptyBox(valueType: ChannelHandlerContext.self, eventLoop: localLoop)
        let remote = NIOLoopBoundBox.makeEmptyBox(valueType: ChannelHandlerContext.self, eventLoop: remoteLoop)
        return (
            SSHGlueHandler(ownContext: local, partnerContext: remote),
            SSHGlueHandler(ownContext: remote, partnerContext: local)
        )
    }

    /// Runs `body` on the partner's loop with its context, if it is still in
    /// its pipeline then.
    private func onPartner(_ body: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        let partner = partnerContext
        if partner.eventLoop.inEventLoop {
            if let context = partner.value { body(context) }
        } else {
            partner.eventLoop.execute {
                if let context = partner.value { body(context) }
            }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        ownContext.value = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        ownContext.value = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        onPartner { partnerContext in partnerContext.write(NIOAny(buffer), promise: nil) }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        onPartner { partnerContext in partnerContext.flush() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onPartner { partnerContext in partnerContext.close(promise: nil) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // Half-closure is not reliable across Network.framework and SSH
            // channels, so drain what is already queued and close fully. Writes
            // are ordered, so the empty write completes after all real data.
            onPartner { partnerContext in
                let drained = partnerContext.eventLoop.makePromise(of: Void.self)
                partnerContext.writeAndFlush(NIOAny(partnerContext.channel.allocator.buffer(capacity: 0)), promise: drained)
                // The glue is last in both pipelines, so closing the channel
                // is closing from this handler.
                let channel = partnerContext.channel
                drained.futureResult.whenComplete { _ in channel.close(promise: nil) }
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
