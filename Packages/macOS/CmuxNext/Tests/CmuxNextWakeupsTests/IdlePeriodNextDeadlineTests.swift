import CmuxNextWakeups
import Testing

/// A long idle period ends before the next main-thread deadline in the app's wiring (sequence-manager-DESIGN.md F1,
/// S1): the scheduler the composition root makes and a ``MainDeadline`` on the ``MainDeadlineScheduler`` made on it,
/// as `AppServices` makes `mainDeadlines`, with nothing else wired. Chrome's `IdleHelper` bounds a long period by the
/// thread's next delayed task (`IdleHelper::ComputeNewLongIdlePeriodState`).
///
/// The deadline is on the scheduler's own wake-up queue, whose clock is `CLOCK_UPTIME_RAW`; the idle clock is a fake
/// that starts at the same uptime and moves only by hand, and the test never runs the main run loop, so the queue's
/// timer never fires and its armed date stays where the schedule put it.
@MainActor @Suite(.timeLimit(.minutes(1))) struct IdlePeriodNextDeadlineTests {
    /// A deadline due 70 ms after the idle post: the long period that starts after 50 ms of quiet ends at the
    /// deadline's wake, 20-28 ms later (the flexible wake snaps up to the 8 ms grid), not at the 50 ms period limit.
    @Test func aLongIdlePeriodEndsBeforeAMainDeadlineDueIn20Ms() throws {
        let clock = PeriodClock()
        let timer = PeriodTimer(clock: clock)
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: NoInputPending(), uptimeNanos: clock.read),
                                             ledger: WakeupLedger(), idleTimer: timer, otherLinks: NoOtherLinks()) { _ in PeriodLink() }
        let deadlines = MainDeadlineScheduler(work: work)
        let deadline = MainDeadline(owner: "test.deadline", workClass: .visible, scheduler: deadlines)
        // The idle clock starts at the queue's uptime right before the schedule, so the two agree to a few us.
        clock.now = WakeupLedger.systemUptime()
        let periodStart = clock.now + 50_000_000
        deadline.schedule(after: .milliseconds(70)) {}
        defer { deadline.cancel() }
        let wake = try #require(deadline.plannedWake?.fire, "the deadline planned no wake")
        let left = wake - .nanoseconds(Int64(periodStart))
        // At least 10 ms short of the 50 ms limit, so a period that ignores the deadline cannot pass.
        try #require(left > .zero && left < .milliseconds(40), "the deadline's wake \(left) after the period start")
        var remaining: Duration?
        work.postIdle(owner: "test.idle") { idle in remaining = idle.timeRemaining }

        timer.run(ms: 51)

        let ran = try #require(remaining, "no long idle period ran after 50 ms of quiet")
        #expect(ran > .zero && ran <= left + .milliseconds(1),
                "the long period ran \(ran), past the MainDeadline that fires \(left) after its start")
    }
}

/// The idle clock (`CLOCK_UPTIME_RAW` nanoseconds), moved by the test.
@MainActor
private final class PeriodClock {
    var now: UInt64 = 0
    var read: () -> UInt64 { { [self] in self.now } }
}

/// The idle period timer, fired by moving the clock.
@MainActor
private final class PeriodTimer: IdlePeriodTimer {
    private let clock: PeriodClock
    private var fire: (@MainActor () -> Void)?
    private var fireAt: UInt64?

    init(clock: PeriodClock) { self.clock = clock }

    func arm(afterNanos delay: UInt64, _ fire: @escaping @MainActor () -> Void) {
        fireAt = clock.now + delay
        self.fire = fire
    }

    func cancel() {
        fireAt = nil
        fire = nil
    }

    /// Moves the clock `ms` on, firing the timer at each due time on the way.
    func run(ms: Double) {
        let end = clock.now + UInt64(ms * 1_000_000)
        while let at = fireAt, at <= end, let pending = fire {
            clock.now = max(clock.now, at)
            fireAt = nil
            fire = nil
            pending()
        }
        clock.now = max(clock.now, end)
    }
}

/// No other scheduler's display link runs.
@MainActor
private final class NoOtherLinks: OtherFrameLinks {
    var anyRunning: Bool { false }
    func add(_ subscription: FrameLinksSubscription) {}
}

@MainActor
private final class PeriodLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
