public import CmuxLink
import Foundation

/// One live, authenticated direct connection (a3-link.md section 8). All
/// lanes ride one Noise-encrypted TCP stream in send order; see
/// b4-direct.md section 4 for the lane mapping.
public final class DirectTransport: LinkTransport {
    /// Frames up to 256 KiB (split into records on the wire); no media tracks.
    public static let capabilities = TransportCapabilities(
        maxFrameBytes: TransportCapabilities.stream.maxFrameBytes, carriesBulk: true, carriesMedia: false
    )

    public let events: AsyncStream<TransportEvent>
    public var capabilities: TransportCapabilities { Self.capabilities }
    /// The authenticated key of the other end.
    public let remoteKey: DirectPublicKey
    let core: DirectTransportCore

    init(
        socket: DirectSocket,
        ciphers: NoiseTransportCiphers,
        path: LinkPath,
        remoteKey: DirectPublicKey,
        handshakeRTT: Duration?,
        injector: DirectFaultInjector?
    ) {
        let (events, continuation) = AsyncStream<TransportEvent>.makeStream()
        self.events = events
        self.remoteKey = remoteKey
        let writer = DirectWriter(socket: socket, cipher: ciphers.send, bytesPerSecond: injector?.currentRate)
        let registration = DirectFaultInjector.Registration()
        let core = DirectTransportCore(
            socket: socket, writer: writer, continuation: continuation, path: path,
            onFinish: { injector?.unregister(registration) }
        )
        self.core = core
        injector?.register(core, as: registration)
        if let handshakeRTT { continuation.yield(.rtt(handshakeRTT)) }
        let receive = ciphers.receive
        let limit = Self.capabilities.maxFrameBytes
        Task { await core.runReceiveLoop(cipher: receive, maxFrameBytes: limit) }
    }

    public var path: LinkPath {
        get async { core.path }
    }

    public func send(_ frame: TransportFrame) async throws {
        guard frame.bytes.count <= Self.capabilities.maxFrameBytes else {
            throw DirectTransportError.frameTooLarge(frame.bytes.count)
        }
        guard !core.isFinished else { throw DirectTransportError.closed }
        try Task.checkCancellation()
        try await core.writer.write(frame)
    }

    public func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle {
        throw DirectTransportError.mediaUnsupported
    }

    /// Graceful: frames accepted before this reach the peer before its
    /// `.closed(.remote)`.
    public func close() async {
        guard !core.isFinished else { return }
        await core.writer.closeGracefully()
        core.finish(.local)
    }
}
