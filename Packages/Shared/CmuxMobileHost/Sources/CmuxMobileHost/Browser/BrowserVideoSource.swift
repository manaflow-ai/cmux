/// Captured and encoded pixels of one attached page, pulled one frame at a
/// time: the handler asks for the next frame only after the previous one
/// left, so a slow path never queues stale frames (newest wins inside the
/// source). Damage-driven: `nextFrame` waits while the page is unchanged.
public protocol BrowserVideoSource: Sendable {
    /// The next changed frame, encoded at `request`'s size and bitrate; a
    /// size change produces a keyframe. Nil when the source ended.
    func nextFrame(_ request: BrowserFrameRequest) async throws -> BrowserEncodedFrame?
    /// The next frame must be a keyframe, and it must come even if the page
    /// did not change (loss recovery, a new viewer size).
    func requestKeyframe() async
}
