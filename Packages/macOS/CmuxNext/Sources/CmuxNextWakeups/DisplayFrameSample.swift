public import QuartzCore
public import CmuxNextSignposts

/// The newest display-link frame a ``DisplayClock`` delivered: a vsync time and the refresh period, so a time
/// can be placed on the display's vsync grid without a display link (nothing asks for a frame to read it).
///
/// Chrome's compositor does the same with its `BeginFrameArgs`: `frame_time + n * interval` is a later vsync of
/// the same source (components/viz/common/frame_sinks/begin_frame_args.h, `BeginFrameArgs::interval`), and
/// presentation feedback without a hardware time is that estimate (ui/gfx/presentation_feedback.h).
///
/// ```swift
/// let sample = displays.newestFrame()
/// let deadline = sample?.vsync(after: turnStart)   // the end of the frame the turn began in
/// ```
public nonisolated struct DisplayFrameSample: Sendable, Equatable {
    /// How old a tick may be for its grid to place a time when no link runs: one second (the period of a
    /// fixed-rate display holds that long; a variable-rate one may not, which ``VsyncPhase/recent`` says).
    public static let maxPhaseAge: CFTimeInterval = 1

    /// The tick's vsync time (the link's `timestamp`, CACurrentMediaTime base).
    public var timestamp: CFTimeInterval
    /// The display's refresh period in seconds (> 0).
    public var interval: Double
    /// A display link was running when the sample was read.
    public var linkRunning: Bool

    /// A sample; nil for a non-positive or non-finite period.
    public init?(timestamp: CFTimeInterval, interval: Double, linkRunning: Bool) {
        guard interval.isFinite, interval > 0, timestamp.isFinite else { return nil }
        self.timestamp = timestamp
        self.interval = interval
        self.linkRunning = linkRunning
    }

    /// Where the grid comes from for a time `time`.
    public func phase(at time: CFTimeInterval) -> VsyncPhase {
        if linkRunning { return .running }
        return abs(time - timestamp) <= Self.maxPhaseAge ? .recent : .unknown
    }

    /// The first vsync strictly after `time`: the deadline of the frame `time` falls in.
    public func vsync(after time: CFTimeInterval) -> CFTimeInterval {
        let frames = ((time - timestamp) / interval).rounded(.down) + 1
        return timestamp + frames * interval
    }

    /// When a Core Animation commit that ended at `commitEnd` is estimated to be shown: the target timestamp of the
    /// first link tick after it. The render server takes the commit in the frame that starts at the first vsync
    /// after it and shows that frame at the frame's target, one period later (`CADisplayLink.targetTimestamp`).
    public func presentEstimate(afterCommit commitEnd: CFTimeInterval) -> CFTimeInterval {
        vsync(after: commitEnd) + interval
    }

    /// ``presentEstimate(afterCommit:)`` and its phase, from `sample` when one exists and its grid holds at
    /// `commitEnd`; otherwise `commitEnd` plus 1.5 periods (the mean of "next vsync, then one frame" over an unknown
    /// phase), with `sample`'s period or ``FrameTick/defaultRefreshInterval``.
    public static func presentEstimate(afterCommit commitEnd: CFTimeInterval,
                                       from sample: DisplayFrameSample?) -> (time: CFTimeInterval, phase: VsyncPhase) {
        if let sample {
            let phase = sample.phase(at: commitEnd)
            if phase != .unknown { return (sample.presentEstimate(afterCommit: commitEnd), phase) }
        }
        let interval = sample?.interval ?? FrameTick.defaultRefreshInterval
        return (commitEnd + 1.5 * interval, .unknown)
    }
}
