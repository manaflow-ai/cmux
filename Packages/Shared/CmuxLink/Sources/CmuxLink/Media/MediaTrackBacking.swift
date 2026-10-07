/// The carrier's implementation behind a `MediaTrackHandle`. WebRTC backs it
/// with its native track; loopback with an in-process frame fan-out.
public protocol MediaTrackBacking: Sendable {
    func states() async -> AsyncStream<MediaTrackState>
    func attach(_ sink: any MediaFrameSink) async
    func detach(_ sink: any MediaFrameSink) async
    /// Publisher side: feeds one frame into the track.
    func push(_ frame: MediaFrame) async
    func stop() async
}
