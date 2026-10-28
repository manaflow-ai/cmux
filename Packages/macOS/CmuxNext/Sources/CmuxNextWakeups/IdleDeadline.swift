/// What an idle task gets: when its idle period ends, and whether it ran because its `maxDelay`
/// passed (Chrome's `IdleDeadline`, `third_party/blink/renderer/core/scheduler/idle_deadline.h`).
///
/// ```swift
/// work.postIdle(owner: "Snapshot.record") { deadline in
///     while let item = pending.first, deadline.timeRemaining > .milliseconds(1) { record(item) }
/// }
/// ```
@MainActor
public struct IdleDeadline {
    /// `CLOCK_UPTIME_RAW` nanoseconds when the idle period ends (0 for a task that timed out).
    public let deadlineNanos: UInt64
    /// True when the task waited past its `maxDelay` and runs as background work, outside any idle
    /// period: ``timeRemaining`` is zero, so a task that slices its work does one slice.
    public let didTimeout: Bool
    private let uptimeNanos: () -> UInt64

    init(deadlineNanos: UInt64, didTimeout: Bool, uptimeNanos: @escaping () -> UInt64) {
        self.deadlineNanos = deadlineNanos
        self.didTimeout = didTimeout
        self.uptimeNanos = uptimeNanos
    }

    /// The time left in the idle period (zero once it is over).
    public var timeRemaining: Duration {
        let now = uptimeNanos()
        return now >= deadlineNanos ? .zero : .nanoseconds(Int64(clamping: deadlineNanos - now))
    }
}

/// The next main-thread deadline that will fire (the `MainDeadline` next-fire registry): a long
/// idle period ends before it, as Chrome's `IdleHelper` bounds a long period by the next pending
/// delayed task (`third_party/blink/renderer/platform/scheduler/common/idle_helper.cc`,
/// `IdleHelper::ComputeNewLongIdlePeriodState`).
@MainActor
public protocol IdleNextDeadlineSource: AnyObject {
    /// `CLOCK_UPTIME_RAW` nanoseconds of the earliest pending deadline; nil when none is pending.
    var nextFireNanos: UInt64? { get }
    /// Called after ``nextFireNanos`` changes: a deadline was added or cancelled, or one fired. The
    /// ``IdleScheduler`` sets it: while a deadline is due it starts no long period and arms no
    /// timer, and this call (not a re-check on a timer) lets the next period start, as Chrome's
    /// `IdleHelper` hears of the delayed task it waits for.
    var onNextFireChange: (@MainActor () -> Void)? { get set }
}
