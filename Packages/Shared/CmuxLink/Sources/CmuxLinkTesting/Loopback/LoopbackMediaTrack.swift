import CmuxLink

/// In-process media track backing: the publisher's pushed frames fan out to
/// every attached sink. Ends with its transport.
public actor LoopbackMediaTrack: MediaTrackBacking {
    private var sinks: [ObjectIdentifier: any MediaFrameSink] = [:]
    private var state: MediaTrackState = .live
    private var stateContinuations: [AsyncStream<MediaTrackState>.Continuation] = []

    public init() {}

    public func states() -> AsyncStream<MediaTrackState> {
        let (stream, continuation) = AsyncStream<MediaTrackState>.makeStream(bufferingPolicy: .bufferingNewest(4))
        continuation.yield(state)
        if state == .ended {
            continuation.finish()
        } else {
            stateContinuations.append(continuation)
        }
        return stream
    }

    public func attach(_ sink: any MediaFrameSink) {
        sinks[ObjectIdentifier(sink)] = sink
    }

    public func detach(_ sink: any MediaFrameSink) {
        sinks[ObjectIdentifier(sink)] = nil
    }

    public func push(_ frame: MediaFrame) {
        guard state == .live else { return }
        for sink in sinks.values { sink.receive(frame) }
    }

    public func setMuted(_ muted: Bool) {
        guard state != .ended else { return }
        set(muted ? .muted : .live)
    }

    public func stop() {
        guard state != .ended else { return }
        set(.ended)
        for continuation in stateContinuations { continuation.finish() }
        stateContinuations.removeAll()
        sinks.removeAll()
    }

    private func set(_ next: MediaTrackState) {
        state = next
        for continuation in stateContinuations { continuation.yield(next) }
    }
}
