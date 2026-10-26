import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// MainDeadline (plans/cmux-next/chrome-parity/p06-scheduler.md, task 011): precise, flexible and hidden alignment,
/// the downgrade of a long precise delay, the 60 s rule for repeating deadlines hidden 5 minutes with one 1 s-aligned
/// wake a minute, the media and capture exemptions, the next-fire registry, and no wakeup while nothing is pending.
/// Every test runs on a manual clock; the node tree reads the same clock.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainDeadlineTests {
    // MARK: Precise and flexible

    @Test func preciseFiresOnTime() async throws {
        let harness = DeadlineHarness()
        let deadline = harness.deadline("precise", alignment: .precise)
        var ran = 0
        deadline.schedule(after: .milliseconds(20)) { ran += 1 }
        #expect(deadline.plannedWake == TimerAlignment.Wake(rule: .precise, due: .milliseconds(20)))
        #expect(harness.scheduler.nextFire == .milliseconds(20))
        try await harness.clock.waitForSleeper()

        harness.clock.advance(by: .milliseconds(19))
        #expect(harness.clock.sleeperCount == 1, "a precise deadline does not wake early")
        await harness.advanceToFire(by: .milliseconds(1))
        #expect(harness.work.postedCount(.visible) == 1, "the wake posts the action in its class")
        #expect(ran == 0, "the action runs as a posted task, not in the wake")
        harness.frame()
        #expect(ran == 1)
        #expect(!deadline.isScheduled)
        #expect(harness.wakeups(MainDeadlineScheduler.ledgerOwner) == 1)
        #expect(harness.wakeups("precise") == 1)
    }

    @Test func aPreciseDelayOf36MillisecondsOrMoreIsDowngradedToFlexible() {
        let harness = DeadlineHarness()
        let short = harness.deadline("short", alignment: .precise)
        let long = harness.deadline("long", alignment: .precise)
        short.schedule(after: .milliseconds(35)) {}
        long.schedule(after: .milliseconds(37)) {}
        #expect(short.plannedWake?.rule == .precise)
        #expect(short.plannedWake?.fire == .milliseconds(35))
        #expect(long.plannedWake?.rule == .flexible)
        #expect(long.plannedWake?.fire == .milliseconds(40), "snapped up to the 8 ms grid")
        #expect(long.plannedWake?.tolerance == TimerAlignment.leeway)
    }

    @Test func flexibleFiresWithinEightMilliseconds() async throws {
        let harness = DeadlineHarness()
        harness.clock.advance(by: .milliseconds(3))
        for delay: Duration in [.zero, .milliseconds(1), .milliseconds(5), .milliseconds(8), .milliseconds(13),
                                .microseconds(250_500), .seconds(2)] {
            let deadline = harness.deadline("flexible")
            deadline.schedule(after: delay) {}
            let wake = try #require(deadline.plannedWake)
            #expect(wake.rule == .flexible)
            #expect(wake.due == .milliseconds(3) + delay)
            #expect(wake.fire >= wake.due, "never sooner than due")
            #expect(wake.fire - wake.due < .milliseconds(8), "within the 8 ms leeway")
            deadline.cancel()
        }

        let deadline = harness.deadline("flexible")
        var ran = 0
        deadline.schedule(after: .milliseconds(10)) { ran += 1 }
        #expect(deadline.plannedWake?.fire == .milliseconds(16), "due at 13 ms, on the 16 ms boundary")
        try await harness.clock.waitForSleeper()
        harness.clock.advance(by: .milliseconds(12))
        #expect(harness.clock.sleeperCount == 1)
        await harness.advanceToFire(by: .milliseconds(1))
        harness.frame()
        #expect(ran == 1)
    }

    // MARK: Hidden

    @Test func aHiddenNodeAlignsToOneSecondAndAVisibleOneIsFlexible() async throws {
        let harness = DeadlineHarness()
        let hidden = harness.node(.hidden)
        let visible = harness.node(.visible)
        let hiddenDeadline = harness.deadline("hidden", alignment: .whenHidden(hidden))
        let visibleDeadline = harness.deadline("visible", alignment: .whenHidden(visible))
        var ran: [String] = []
        hiddenDeadline.schedule(after: .milliseconds(300)) { ran.append("hidden") }
        visibleDeadline.schedule(after: .milliseconds(300)) { ran.append("visible") }
        #expect(hiddenDeadline.plannedWake == TimerAlignment.Wake(rule: .hidden, due: .milliseconds(300)))
        #expect(hiddenDeadline.plannedWake?.fire == .seconds(1))
        #expect(visibleDeadline.plannedWake?.rule == .flexible)
        #expect(visibleDeadline.plannedWake?.fire == .milliseconds(304))

        try await harness.clock.waitForSleeper()
        await harness.advanceToFire(by: .milliseconds(304))
        harness.frame()
        #expect(ran == ["visible"])
        try await harness.clock.waitForSleeper()
        harness.clock.advance(by: .milliseconds(695))
        #expect(harness.clock.sleeperCount == 1, "the hidden deadline waits for its 1 s boundary")
        await harness.advanceToFire(by: .milliseconds(1))
        harness.frame()
        #expect(ran == ["visible", "hidden"])
    }

    @Test func aOneShotDeadlineHiddenFiveMinutesStaysAtOneSecond() {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        harness.clock.advance(by: .seconds(300))
        let deadline = harness.deadline("one-shot", alignment: .whenHidden(node))
        deadline.schedule(after: .milliseconds(1_500)) {}
        #expect(deadline.plannedWake?.rule == .hidden)
        #expect(deadline.plannedWake?.fire == .seconds(302))
    }

    @Test func aRepeatingDeadlineHiddenFiveMinutesWakesEverySixtySeconds() async throws {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        harness.clock.advance(by: .seconds(10))
        let early = harness.deadline("early", alignment: .whenHidden(node))
        early.start(every: .seconds(1)) {}
        #expect(early.plannedWake?.rule == .hidden, "hidden 11 s at its due time: 1 s alignment")
        early.cancel()

        harness.clock.advance(by: .seconds(290))
        let poll = harness.deadline("poll", workClass: .background, alignment: .whenHidden(node))
        var runs = 0
        poll.start(every: .seconds(1)) { runs += 1 }
        #expect(poll.plannedWake?.rule == .intensive)
        #expect(poll.plannedWake?.fire == .seconds(301), "no wake in the last minute: a 1 s-aligned wake is allowed")

        await harness.advanceToFire(by: .seconds(1))
        harness.frame()
        #expect(runs == 1)
        #expect(poll.plannedWake?.fire == .seconds(360), "the next wake is on the minute")

        try await harness.clock.waitForSleeper()
        harness.clock.advance(by: .seconds(58))
        #expect(harness.clock.sleeperCount == 1)
        await harness.advanceToFire(by: .seconds(1))
        harness.frame()
        #expect(runs == 2)
        #expect(poll.plannedWake?.fire == .seconds(420))
        #expect(harness.wakeups("poll") == 2)
    }

    @Test func aDeadlineScheduledFromItsOwnActionCountsAsRepeating() async throws {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        harness.clock.advance(by: .seconds(300))
        let deadline = harness.deadline("self-arming", alignment: .whenHidden(node))
        deadline.schedule(after: .seconds(1)) { [weak deadline] in deadline?.schedule(after: .seconds(1)) {} }
        #expect(deadline.plannedWake?.rule == .hidden, "a first one-shot schedule is not repeating")
        await harness.advanceToFire(by: .seconds(1))
        harness.frame()
        #expect(deadline.plannedWake?.rule == .intensive)
        #expect(deadline.plannedWake?.fire == .seconds(302), "no intensive wake yet: one 1 s-aligned wake is allowed")
    }

    @Test func theIntensiveRuleAllowsOneAlignedWakeAMinute() {
        let last: Duration = .seconds(360)
        #expect(TimerAlignment.Wake(rule: .intensive, due: .milliseconds(362_200), lastIntensiveWake: last).fire == .seconds(420))
        #expect(TimerAlignment.Wake(rule: .intensive, due: .milliseconds(425_300), lastIntensiveWake: last).fire == .seconds(426),
                "a minute after the last wake: the next 1 s boundary")
        #expect(TimerAlignment.Wake(rule: .intensive, due: .milliseconds(10_300)).fire == .seconds(11), "no wake yet")
    }

    @Test func recentMediaOrACaptureVoteDisablesAlignment() {
        var captured = false
        let harness = DeadlineHarness(isCaptured: { _ in captured })
        let node = harness.node(.hidden)
        let deadline = harness.deadline("media", alignment: .whenHidden(node))

        node.setMediaActive(true)
        deadline.schedule(after: .milliseconds(300)) {}
        #expect(deadline.plannedWake?.rule == .flexible, "playing media")
        node.setMediaActive(false)
        harness.clock.advance(by: .seconds(29))
        deadline.schedule(after: .milliseconds(300)) {}
        #expect(deadline.plannedWake?.rule == .flexible, "media 29 s ago")
        harness.clock.advance(by: .seconds(1))
        deadline.schedule(after: .milliseconds(300)) {}
        #expect(deadline.plannedWake?.rule == .hidden, "media 30 s ago")

        captured = true
        deadline.schedule(after: .milliseconds(300)) {}
        #expect(deadline.plannedWake?.rule == .flexible, "a capture vote")
    }

    @Test func showingTheNodeReplansAPendingHiddenDeadline() async throws {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        let deadline = harness.deadline("reveal", alignment: .whenHidden(node))
        var ran = 0
        deadline.schedule(after: .milliseconds(300)) { ran += 1 }
        #expect(deadline.plannedWake?.fire == .seconds(1))
        node.set(.visible)
        #expect(deadline.plannedWake?.rule == .flexible)
        #expect(deadline.plannedWake?.fire == .milliseconds(304))
        #expect(harness.scheduler.nextFire == .milliseconds(304))
        await harness.advanceToFire(by: .milliseconds(304))
        harness.frame()
        #expect(ran == 1)
    }

    // MARK: Registry

    @Test func nextFireIsTheEarliest() {
        let harness = DeadlineHarness()
        var changes = 0
        harness.scheduler.onNextFireChange = { changes += 1 }
        let hidden = harness.deadline("hidden", alignment: .whenHidden(harness.node(.hidden)))
        let flexible = harness.deadline("flexible")
        let precise = harness.deadline("precise", alignment: .precise)
        hidden.schedule(after: .milliseconds(300)) {}
        flexible.schedule(after: .milliseconds(500)) {}
        precise.schedule(after: .milliseconds(20)) {}
        #expect(harness.scheduler.nextFire == .milliseconds(20))
        #expect(harness.scheduler.nextFireNanos == 20_000_000, "the same instant on the uptime clock")
        #expect(harness.scheduler.pendingCount == 3)
        #expect(changes == 3, "1 s, then 504 ms, then 20 ms")

        precise.cancel()
        #expect(harness.scheduler.nextFire == .milliseconds(504))
        flexible.cancel()
        #expect(harness.scheduler.nextFire == .seconds(1))
        hidden.cancel()
        #expect(harness.scheduler.nextFire == nil)
        #expect(harness.scheduler.nextFireNanos == nil)
        #expect(changes == 6)
        #expect(!harness.scheduler.isArmed)
    }

    @Test func noWakeupsWhenEmpty() async throws {
        let harness = DeadlineHarness()
        harness.clock.advance(by: .seconds(600))
        #expect(harness.clock.sleeperCount == 0)
        #expect(harness.scheduler.nextFire == nil)
        #expect(harness.ledger.snapshot().isEmpty)

        let deadline = harness.deadline("cancelled")
        deadline.schedule(after: .milliseconds(100)) {}
        try await harness.clock.waitForSleeper()
        deadline.cancel()
        #expect(harness.clock.sleeperCount == 0, "the last cancel stops the sleep")
        harness.clock.advance(by: .seconds(600))
        #expect(harness.ledger.snapshot().isEmpty, "nothing woke")
    }

    @Test func cancellingAfterTheWakeDropsThePostedAction() async throws {
        let harness = DeadlineHarness()
        let deadline = harness.deadline("late-cancel", workClass: .automation)
        var ran = 0
        deadline.schedule(after: .milliseconds(8)) { ran += 1 }
        await harness.advanceToFire(by: .milliseconds(8))
        #expect(harness.work.postedCount(.automation) == 1)
        #expect(deadline.isScheduled, "scheduled until the action runs")
        deadline.cancel()
        harness.frame()
        #expect(ran == 0)
    }

    @Test func aReleasedDeadlineNeverRunsAndItsWakeIsDropped() async throws {
        let harness = DeadlineHarness()
        var ran = 0
        var released: MainDeadline? = harness.deadline("released")
        released?.schedule(after: .milliseconds(48)) { ran += 1 }
        released = nil
        await harness.advanceToFire(by: .milliseconds(48))
        harness.frame()
        #expect(ran == 0)
        #expect(harness.work.postedCount(.visible) == 0)
        #expect(harness.wakeups("released") == 0)
        #expect(harness.scheduler.pendingCount == 0)

        var dropped: MainDeadline? = harness.deadline("dropped")
        dropped?.schedule(after: .milliseconds(48)) {}
        dropped = nil
        let kept = harness.deadline("kept")
        kept.schedule(after: .milliseconds(96)) {}
        #expect(harness.scheduler.pendingCount == 1, "the next re-arm drops the released deadline's wake")
        #expect(harness.scheduler.nextFire == .milliseconds(96), "armed for the kept deadline only")
    }

    @Test func deadlinesDueTogetherShareOneWake() async throws {
        let harness = DeadlineHarness()
        var ran: [String] = []
        let deadlines = (0..<5).map { harness.deadline("shared \($0)") }
        for (index, deadline) in deadlines.enumerated() {
            deadline.schedule(after: .milliseconds(17 + index)) { ran.append("shared \(index)") }
        }
        #expect(harness.scheduler.nextFire == .milliseconds(24))
        await harness.advanceToFire(by: .milliseconds(24))
        harness.frame()
        #expect(ran == (0..<5).map { "shared \($0)" })
        #expect(harness.wakeups(MainDeadlineScheduler.ledgerOwner) == 1)
    }
}

/// A deadline scheduler on a manual clock, a main-thread scheduler whose posts wait for hand-fired frames, and a
/// visibility tree on the same clock.
@MainActor
private final class DeadlineHarness {
    let clock: ManualClock
    let ledger: WakeupLedger
    let work: MainWorkScheduler
    let scheduler: MainDeadlineScheduler
    private let keeper: FrameClient
    private let budgetClock: FrameUptime
    private var frames: Double = 0
    private var nodes: [VisibilityNode] = []
    /// How many times the scheduler's next fire moved (each wake moves it).
    private var changes = 0
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    init(isCaptured: @escaping @MainActor (VisibilityNode) -> Bool = { _ in false }) {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let budgetClock = FrameUptime()
        self.clock = clock
        self.ledger = ledger
        self.budgetClock = budgetClock
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: budgetClock.read)) { _ in DeadlineFakeLink() }
        self.work = work
        scheduler = MainDeadlineScheduler(work: work, clock: clock, uptime: { clock.now.offset }, ledger: ledger,
                                          isCaptured: isCaptured)
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        self.keeper = keeper
        keeper.activate()
        scheduler.onNextFireChange = { [weak self] in self?.noteChange() }
    }

    func deadline(_ owner: String, workClass: BudgetedWorkClass = .visible,
                  alignment: TimerAlignment = .flexible) -> MainDeadline {
        MainDeadline(owner: owner, workClass: workClass, alignment: alignment, scheduler: scheduler)
    }

    /// A root node on the harness clock, kept alive by the harness.
    func node(_ own: Visibility) -> VisibilityNode {
        let clock = clock
        let node = VisibilityNode(root: "test.node", own: own, uptime: { clock.now.offset })
        nodes.append(node)
        return node
    }

    /// Moves the clock by `duration` and returns once the scheduler's wake ran (a wake always moves the next fire).
    func advanceToFire(by duration: Duration) async {
        let target = changes + 1
        clock.advance(by: duration)
        guard changes < target else { return }
        await withCheckedContinuation { waiter = (target, $0) }
    }

    /// One display frame: posted actions run.
    func frame() {
        budgetClock.now += 17_000_000
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
    }

    func wakeups(_ owner: String) -> UInt64 {
        ledger.snapshot().filter { $0.owner == owner }.reduce(0) { $0 + $1.count }
    }

    private func noteChange() {
        changes += 1
        if let waiter, changes >= waiter.count {
            self.waiter = nil
            waiter.continuation.resume()
        }
    }
}

/// The budget's clock (`CLOCK_UPTIME_RAW` nanoseconds), one 60 Hz frame further at each hand-fired frame.
@MainActor
private final class FrameUptime {
    var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
}

@MainActor
private final class DeadlineFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
