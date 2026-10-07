import CmuxLink

/// One end of a `LoopbackPipe`.
public final class LoopbackTransport: LinkTransport {
    let pipe: LoopbackPipe
    let side: Int
    public let events: AsyncStream<TransportEvent>
    public let capabilities: TransportCapabilities

    init(pipe: LoopbackPipe, side: Int, events: AsyncStream<TransportEvent>, capabilities: TransportCapabilities) {
        self.pipe = pipe
        self.side = side
        self.events = events
        self.capabilities = capabilities
    }

    public var path: LinkPath {
        get async { await pipe.path }
    }

    public func send(_ frame: TransportFrame) async throws {
        try await pipe.send(frame, from: side)
    }

    public func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle {
        try await pipe.publishMediaTrack(descriptor, from: side)
    }

    public func close() async {
        await pipe.close(from: side)
    }
}
