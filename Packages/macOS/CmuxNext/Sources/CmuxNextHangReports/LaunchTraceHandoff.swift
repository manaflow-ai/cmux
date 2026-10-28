/// A slow launch's trace (``HangReport/LaunchTrace``, p08-startup-111) on its way to the collector. The collector drops
/// what it is handed while reports are off, and at `startup_complete` the setting may not have been read yet, so the
/// trace waits here for the first on/off decision.
///
/// ```swift
/// handoff.note(trace, collector: collector)       // at startup_complete
/// handoff.decide(on, collector: collector)        // each time reports are turned on or off
/// ```
@MainActor
public final class LaunchTraceHandoff {
    private var decided = false
    private var pending: HangReport.LaunchTrace?

    /// An empty hand-off: nothing decided, nothing waiting.
    public init() {}

    /// Hands `trace` to `collector` once reports were decided; before that, keeps it (the newest one).
    public func note(_ trace: HangReport.LaunchTrace, collector: HangReportCollector) {
        if decided { collector.noteLaunchTrace(trace) } else { pending = trace }
    }

    /// Reports were turned on or off: a waiting trace goes to `collector` when on, and is dropped either way after.
    public func decide(_ on: Bool, collector: HangReportCollector) {
        decided = true
        if on, let pending { collector.noteLaunchTrace(pending) }
        pending = nil
    }
}
