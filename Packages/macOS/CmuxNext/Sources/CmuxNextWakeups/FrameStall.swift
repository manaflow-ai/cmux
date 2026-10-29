public import QuartzCore

/// One frame stall a ``FrameScheduler`` saw: no display frame came for ``FrameScheduler/stallTimeout``
/// while clients were active, so the clients ticked without the link.
///
/// The times are `CACurrentMediaTime` seconds (the display link's timebase). ``startedAt`` is the
/// last frame's timestamp, not the time the stall timer noticed, so a report or trace shows when
/// the frames stopped.
public struct FrameStall: Sendable, Equatable {
    /// The last display frame before the stall (or the time the clients activated, when no frame came).
    public var startedAt: CFTimeInterval
    /// When the scheduler saw the stall and ticked its clients without the link.
    public var detectedAt: CFTimeInterval

    /// - Parameters:
    ///   - startedAt: The last frame's timestamp.
    ///   - detectedAt: The time the stall was seen.
    public init(startedAt: CFTimeInterval, detectedAt: CFTimeInterval) {
        self.startedAt = startedAt
        self.detectedAt = detectedAt
    }
}
