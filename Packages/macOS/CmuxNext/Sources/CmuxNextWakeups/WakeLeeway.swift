import Foundation

/// The window a delayed wake may fire in, so that deadlines close to each other share one wake.
///
/// Chromium gives every delayed task the same leeway, `kDefaultLeeway` = 8 ms
/// (`base/task/task_features.h`), and with `kAlignWakeUps` snaps the wake to an 8 ms boundary of
/// `TimeTicks` (`base/message_pump.cc`, `AdjustDelayedRunTime`, clamped to the latest time).
/// cmux keeps that below 1 s and goes past it above:
///
/// | delay, policy                          | leeway           | grid                |
/// |----------------------------------------|------------------|---------------------|
/// | 0 or less, or precise below 36 ms      | 0                | none (exact)        |
/// | below 1 s, flexible or precise 36 ms+  | alignment (8 ms) | alignment (8 ms)    |
/// | 1 s or more                            | min(10%, 1 s)    | whole uptime second |
///
/// Why cmux differs from Chrome's flat 8 ms: most cmux deadlines are debounces, retries and
/// timeouts of seconds, and an 8 ms grid almost never puts two of them in the same wake. Apple's
/// Energy Efficiency Guide for Mac Apps ("Minimize Timer Usage") asks for a tolerance of at least
/// 10% of the interval, and Blink runs background-page timers on a 1 s grid
/// (`third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.h`).
/// The 1 s cap keeps a 60 s timeout from slipping by 6 s. In Energy Saver the alignment is 32 ms,
/// Chrome's `kBatterySaverModeAlignWakeUps` value (`MessagePump::OverrideAlignWakeUpsState`).
///
/// Instants are uptime nanoseconds (`CLOCK_UPTIME_RAW`, the origin of Chromium's `TimeTicks` on
/// macOS), so a grid boundary is the same instant for every queue in the process.
public struct WakeLeeway: Sendable, Hashable {
    /// Chromium's `kDefaultLeeway` on macOS: the leeway and grid of a flexible delay below 1 s.
    public static let defaultAlignment: Duration = .milliseconds(8)
    /// The leeway and grid of a flexible delay below 1 s while Energy Saver is on.
    public static let saverAlignment: Duration = .milliseconds(32)
    /// From this delay on, the grid is one uptime second and the leeway 10% of the delay.
    public static let wholeSecondDelay: Duration = .seconds(1)
    /// The largest leeway any delay gets.
    public static let maxLeeway: Duration = .seconds(1)

    /// The delay the window was made for.
    public let delay: Duration
    /// The policy after ``DelayPolicy/effective(for:)``: never `.precise` at 36 ms or more.
    public let policy: DelayPolicy
    /// How far from the deadline the wake may move: after it for `.flexibleNoSooner`, before it for
    /// `.flexiblePreferEarly`, zero for `.precise`.
    public let leeway: Duration
    /// The boundary a wake snaps to inside the window; `.zero` when the wake is exact.
    public let grid: Duration
    /// The wake snaps to the energy policy's sub-second alignment at wake time instead of ``grid``: a
    /// flexible window of the table below 1 s. A window with its caller's own tolerance
    /// (``own(tolerance:delay:)``) and a whole-second window keep their own grid.
    public let followsAlignment: Bool

    init(delay: Duration, policy: DelayPolicy, leeway: Duration, grid: Duration, followsAlignment: Bool? = nil) {
        self.delay = delay
        self.policy = policy
        self.leeway = leeway
        self.grid = grid
        self.followsAlignment = followsAlignment ?? (policy != .precise && grid < Self.wholeSecondDelay)
    }

    /// The window for a wake `delay` from now. `alignment` is the sub-second grid: 8 ms
    /// (``defaultAlignment``), 32 ms in Energy Saver (``saverAlignment``); a value that is not
    /// positive is read as 8 ms.
    public static func window(delay: Duration, policy: DelayPolicy = .flexibleNoSooner,
                              alignment: Duration = WakeLeeway.defaultAlignment) -> WakeLeeway {
        let effective = policy.effective(for: delay)
        if effective == .precise {
            return WakeLeeway(delay: delay, policy: effective, leeway: .zero, grid: .zero)
        }
        if delay >= wholeSecondDelay {
            return WakeLeeway(delay: delay, policy: effective, leeway: min(delay / 10, maxLeeway), grid: .seconds(1))
        }
        let step = alignment > .zero ? alignment : defaultAlignment
        return WakeLeeway(delay: delay, policy: effective, leeway: step, grid: step)
    }

    /// The window of a wake that keeps its caller's own tolerance instead of the table's: no sooner than
    /// the deadline, at most `tolerance` after it, snapped to a `tolerance` grid inside that window. The
    /// energy policy's alignment never replaces that grid, so Energy Saver does not move the wake. A
    /// tolerance or delay of zero or less is exact (`.precise`). This is a run-loop timer's own
    /// tolerance (`CFRunLoopTimerSetTolerance`) on the shared queue: the CEF pump's wakes, whose
    /// Chromium tasks reach cmux without their precise or flexible policy.
    public static func own(tolerance: Duration, delay: Duration) -> WakeLeeway {
        guard tolerance > .zero, delay > .zero else {
            return WakeLeeway(delay: delay, policy: .precise, leeway: .zero, grid: .zero)
        }
        return WakeLeeway(delay: delay, policy: .flexibleNoSooner, leeway: tolerance, grid: tolerance, followsAlignment: false)
    }

    /// The tolerance for `clock.sleep(for: sleepDelay, tolerance:)`: the leeway (zero when precise).
    public var tolerance: Duration { leeway }

    /// The relative sleep that honors the window: `delay`, or `delay - leeway` for
    /// `.flexiblePreferEarly` (a clock sleep can only fire late). Never below zero.
    public var sleepDelay: Duration {
        policy == .flexiblePreferEarly ? max(delay - leeway, .zero) : delay
    }

    /// The first instant the wake for `deadline` may fire (uptime ns).
    public func earliest(deadline: UInt64) -> UInt64 {
        policy == .flexiblePreferEarly ? deadline.subtractingSaturated(leeway.nanosecondCount) : deadline
    }

    /// The last instant the wake for `deadline` may fire (uptime ns).
    public func latest(deadline: UInt64) -> UInt64 {
        policy == .flexibleNoSooner ? deadline.addingSaturated(leeway.nanosecondCount) : deadline
    }

    /// The instant the wake for `deadline` fires when nothing else shares it: the first grid boundary
    /// at or after ``earliest(deadline:)``, but never after ``latest(deadline:)`` (Chromium's
    /// `std::min(aligned, latest_time)`). Exact wakes fire at `deadline`.
    public func fireTime(deadline: UInt64) -> UInt64 {
        fireTime(deadline: deadline, grid: grid)
    }

    /// ``fireTime(deadline:)`` on `grid` instead of the window's own: the alignment in force at wake
    /// time, which `MessagePump::AdjustDelayedRunTime` reads then, not when the task was posted.
    public func fireTime(deadline: UInt64, grid: Duration) -> UInt64 {
        let step = grid.nanosecondCount
        let start = self.earliest(deadline: deadline)
        guard step > 0 else { return start }
        let remainder = start % step
        let aligned = remainder == 0 ? start : start.addingSaturated(step - remainder)
        return min(aligned, self.latest(deadline: deadline))
    }
}

extension Duration {
    /// This duration in whole nanoseconds; negative durations are zero.
    var nanosecondCount: UInt64 {
        let (seconds, attoseconds) = components
        guard seconds >= 0, self > .zero else { return 0 }
        return UInt64(seconds).multipliedSaturated(1_000_000_000).addingSaturated(UInt64(attoseconds / 1_000_000_000))
    }
}

extension UInt64 {
    fileprivate func addingSaturated(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }

    fileprivate func subtractingSaturated(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }

    fileprivate func multipliedSaturated(_ other: UInt64) -> UInt64 {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? .max : product
    }
}
