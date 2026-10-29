/// Where ``RenderStarvationGuard`` finds the main-thread turn to blame in `stall.render_starved`:
/// the run loop turn meter (`MainTurnMeter`, plans/cmux-next/chrome-parity/p06-scheduler.md task
/// 008) conforms; tests pass a fake.
///
/// A turn's unattributed time is what no scheduled task, render pass or input dispatch explains: a
/// main-actor job, a timer or a callout nobody posted through the scheduler.
@MainActor
public protocol UnattributedTurnSource: AnyObject {
    /// The turn with the most unattributed time among those that ended after `sinceNanos`
    /// (`CLOCK_UPTIME_RAW` nanoseconds), the one still running included, or nil when none had any.
    /// A turn that started before `sinceNanos` counts: the late link's last tick is a callout inside
    /// a turn, and a job later in that turn is what kept the next tick from running. Called once
    /// per starvation.
    func topUnattributedTurn(endingAfter sinceNanos: UInt64) -> UnattributedTurn?
}

/// One main run loop turn, as the turn meter names it.
public struct UnattributedTurn: Sendable, Equatable {
    /// What the meter knows of the turn: the job, timer or run loop activity it saw.
    public var label: String
    /// When the turn started (`CLOCK_UPTIME_RAW` nanoseconds).
    public var startNanos: UInt64
    /// The whole turn.
    public var durationNanos: UInt64
    /// The part no scheduled task, render pass or input dispatch explains.
    public var unattributedNanos: UInt64

    /// A turn from its parts (the meter records them; tests build them).
    public init(label: String, startNanos: UInt64, durationNanos: UInt64, unattributedNanos: UInt64) {
        self.label = label
        self.startNanos = startNanos
        self.durationNanos = durationNanos
        self.unattributedNanos = unattributedNanos
    }
}
