public import AppKit

/// When a main-thread commit reaches the glass, for ``InputLatencyTracker``'s ``CmuxNextInputCore/InputStage/presented``
/// stage. The app's is CmuxNextWakeups' `PresentationClock` (the commit's vsync plus one render-server frame plus the
/// per-OS offset, p04-input-003); tests pass a fake.
///
/// Chrome closes an `EventMetrics` at the presentation feedback of the frame that shows it
/// (cc/metrics/compositor_frame_reporter.cc); AppKit content gets no feedback, so this is the estimate.
@MainActor
public protocol InputPresentationEstimating: AnyObject {
    /// Keeps `window`'s display link subscribed for a few frames after a tracked input, so the commit that follows
    /// reads a real vsync instead of an extrapolated one. Nil: the window-less app scheduler.
    func holdLinkForInput(in window: NSWindow?)

    /// The estimated presentation time of a commit that ended at `commitEndNanos` (`CLOCK_UPTIME_RAW`) in `window`.
    /// Starts no display link.
    func presentedNanos(commitEndNanos: UInt64, in window: NSWindow?) -> UInt64
}
