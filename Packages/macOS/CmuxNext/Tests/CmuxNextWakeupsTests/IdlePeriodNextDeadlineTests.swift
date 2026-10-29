@testable import CmuxNextWakeups
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

    /// A wake due in under 1 ms holds the long period, with no idle timer re-poll; the wake's fire (the queue's, not
    /// the idle timer's) lets the period start, and the watch that hears it rides that fire unrecorded.
    @Test func aDueWakeHoldsTheLongPeriodUntilItFires() {
        let rig = DueRig()
        var ran = 0
        rig.work.postIdle(owner: "test.idle") { _ in ran += 1 }
        rig.idle.run(ms: 20)
        // Precise only under 36 ms (a longer precise delay is flexible): due 0.5 ms after the period would start.
        rig.queue.insert(owner: "test.due", after: .microseconds(30_500), policy: .precise) {}

        rig.idle.run(ms: 30.2)
        #expect(ran == 0, "a long period ran with a wake due in 0.3 ms")
        #expect(rig.idle.fireAt == nil, "the idle timer re-polls a due wake")

        rig.wakes.fire()
        rig.idle.run(ms: 1)
        #expect(ran == 1, "the due wake's fire did not let the long period start")
        #expect(rig.wakes.deadlines(of: WakeUpQueueNextFire.owner) == 0, "the watch that rode a fire recorded a wake")
    }

    /// The due wake's entry is cancelled: the watch fires on its own wake and lets the period start.
    @Test func aCancelledDueWakeStillEndsTheHold() {
        let rig = DueRig()
        var ran = 0
        rig.work.postIdle(owner: "test.idle") { _ in ran += 1 }
        rig.idle.run(ms: 20)
        let token = rig.queue.insert(owner: "test.due", after: .microseconds(30_500), policy: .precise) {}
        rig.idle.run(ms: 30.2)
        #expect(ran == 0)

        rig.queue.cancel(token)
        rig.wakes.fire()
        rig.idle.run(ms: 1)
        #expect(ran == 1, "the hold outlived the cancelled wake")
        #expect(rig.wakes.deadlines(of: WakeUpQueueNextFire.owner) == 1)
    }
}

/// A scheduler whose deadline queue and idle timer share one fake uptime, both fired by hand.
@MainActor
private struct DueRig {
    let wakes: WakeUpQueueRig
    let idle: UptimeIdleTimer
    let work: MainWorkScheduler
    var queue: MainWakeUpQueue { wakes.queue }

    init() {
        let wakes = WakeUpQueueRig(start: 10_000_000_000), uptime = wakes.uptime
        self.wakes = wakes
        idle = UptimeIdleTimer(uptime: uptime)
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: NoInputPending(), uptimeNanos: { uptime.now }),
                                         ledger: WakeupLedger(), idleTimer: idle, otherLinks: NoOtherLinks(),
                                         wakeUps: wakes.queue) { _ in PeriodLink() }
    }
}

/// The idle period timer on the rig's uptime, fired by moving it.
@MainActor
private final class UptimeIdleTimer: IdlePeriodTimer {
    private let uptime: FakeUptime
    private var fire: (@MainActor () -> Void)?
    private(set) var fireAt: UInt64?

    init(uptime: FakeUptime) { self.uptime = uptime }

    func arm(afterNanos delay: UInt64, _ fire: @escaping @MainActor () -> Void) {
        fireAt = uptime.now + delay
        self.fire = fire
    }

    func cancel() {
        fireAt = nil
        fire = nil
    }

    func run(ms: Double) {
        let end = uptime.now + UInt64(ms * 1_000_000)
        while let at = fireAt, at <= end, let pending = fire {
            uptime.now = max(uptime.now, at)
            fireAt = nil
            fire = nil
            pending()
        }
        uptime.now = max(uptime.now, end)
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
