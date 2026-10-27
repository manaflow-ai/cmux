import CmuxNextWakeups

/// One record of the startup trace ring: what happened, on which thread, and when, in `CLOCK_UPTIME_RAW`
/// nanoseconds (the clock of every cmux trace, plans/cmux-next/trace.md). A fixed-size value, so the ring is
/// one preallocated array; only a launch mark carries a `String` (its name).
struct StartupTraceRecord: Sendable {
    enum Event: Sendable {
        /// A launch mark (`DebugTimings.markLaunch`): an instant.
        case mark(String)
        /// A startup task (the StartupScheduler's posts): a slice.
        case task(StaticString)
        /// A main-thread turn (run-loop wake to sleep) past the threshold, from the watchdog: a slice.
        case mainTurn
        /// A ``BackgroundWork`` item on its lane: a slice.
        case laneJob(BlockingLane, WorkPriority)
    }

    var event: Event
    var start: UInt64
    /// The end of a slice; equal to ``start`` for an instant.
    var end: UInt64
    var thread: UInt64
}
