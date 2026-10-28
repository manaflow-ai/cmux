public import AppKit
public import CmuxNextWakeups

/// When content committed at a time reaches the glass, for ``InputLatencyTracker``'s
/// ``CmuxNextInputCore/InputStage/presented`` stage. The app's is CmuxNextWakeups' `PresentationClock` (the
/// commit's vsync plus one render-server frame plus the per-OS offset); tests pass a fake.
///
/// Chrome closes an `EventMetrics` at the presentation feedback of the frame that shows it
/// (cc/metrics/compositor_frame_reporter.cc), and the feedback says how its time was found (`kVSync` and the other
/// `gfx::PresentationFeedback` flags). AppKit content gets no feedback, so this is an estimate that carries its
/// ``PresentedEstimate/basis`` and whether the display has a variable refresh rate.
@MainActor
public protocol InputPresentationEstimating: AnyObject {
    /// Keeps `window`'s display link subscribed for a few frames after a tracked input, so the commit that follows
    /// is resolved by a real vsync instead of an extrapolated one. Nil: the window-less app scheduler.
    func holdLinkForInput(in window: NSWindow?)

    /// Resolves the presented time of content committed at `nanos` (`CLOCK_UPTIME_RAW`) in `window`: `resolve` runs
    /// once, at the next real tick of a held or running link, or before this returns when no link runs. Starts no
    /// display link.
    ///
    /// - Parameters:
    ///   - nanos: When the content was committed (the turn's Core Animation commit, or the target's submission).
    ///   - window: The content's window, or nil for the app scheduler.
    ///   - resolve: Receives the estimate. The tracker passes a closure it built once, so the call allocates nothing.
    func presented(committedAt nanos: UInt64, in window: NSWindow?, _ resolve: @escaping PresentationClock.Resolve)
}
