@testable import CmuxNextWakeups
import Testing

/// MainDeadline (plans/cmux-next/chrome-parity/p06-scheduler.md, tasks 011 and 012b): precise, flexible and hidden
/// alignment on the main thread's one MainWakeUpQueue, the downgrade of a long precise delay, the node's wake-up
/// budget for repeating deadlines hidden 5 minutes (one wake a minute for the whole node, one 1 s-aligned wake when
/// it had none in the last minute), the media and capture exemptions (also for a pending wake), the next-fire
/// registry, and no wakeup while nothing is pending. Every test runs on WakeUpQueueRig's fake timer and uptime; the
/// node tree reads the same uptime.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainDeadlineTests {
    // MARK: Precise and flexible

    @Test func preciseFiresOnTime() {
        let harness = DeadlineHarness()
        let deadline = harness.deadline("precise", alignment: .precise)
        var ran = 0
        deadline.schedule(after: .milliseconds(20)) { ran += 1 }
        let wake = deadline.plannedWake
        #expect(wake?.rule == .precise)
        #expect(wake?.fire == .milliseconds(20))
        #expect(wake?.tolerance == .zero)
        #expect(harness.scheduler.nextFire == .milliseconds(20))
        #expect(harness.rig.timer.arms.last == FakeWakeUpTimer.Arm(date: 20 * ms, tolerance: 0), "no early wake, no slack")

        harness.rig.fire()
        #expect(harness.work.postedCount(.visible) == 1, "the wake posts the action in its class")
        #expect(ran == 0, "the action runs as a posted task, not in the wake")
        harness.frame()
        #expect(ran == 1)
        #expect(!deadline.isScheduled)
        #expect(harness.rig.fires == 1)
        #expect(harness.rig.deadlines(of: "precise") == 1)
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
        #expect(long.plannedWake?.tolerance == WakeLeeway.defaultAlignment)
    }

    @Test func flexibleFiresInWakeLeewaysWindow() throws {
        let harness = DeadlineHarness()
        harness.rig.uptime.now = 3 * ms
        for delay: Duration in [.milliseconds(1), .milliseconds(5), .milliseconds(8), .milliseconds(13),
                                .microseconds(250_500), .seconds(2)] {
            let deadline = harness.deadline("flexible")
            deadline.schedule(after: delay) {}
            let wake = try #require(deadline.plannedWake)
            #expect(wake.rule == .flexible)
            #expect(wake.due == .milliseconds(3) + delay)
            #expect(wake.tolerance == WakeLeeway.window(delay: delay).leeway, "the same leeway every queue user gets")
            #expect(wake.fire >= wake.due, "never sooner than due")
            #expect(wake.fire - wake.due <= wake.tolerance, "within the leeway")
            deadline.cancel()
        }

        let deadline = harness.deadline("flexible")
        var ran = 0
        deadline.schedule(after: .milliseconds(10)) { ran += 1 }
        #expect(deadline.plannedWake?.fire == .milliseconds(16), "due at 13 ms, on the 16 ms uptime boundary")
        #expect(harness.rig.timer.armedDate == 16 * ms)
        harness.rig.fire()
        harness.frame()
        #expect(ran == 1)
    }

    @Test func flexibleUsesTheQueuesAlignment() {
        let harness = DeadlineHarness(energy: EnergyPolicySource(EnergyPolicy(saverReason: .setting)))
        let deadline = harness.deadline("saver")
        deadline.schedule(after: .milliseconds(10)) {}
        #expect(deadline.plannedWake?.fire == .milliseconds(32), "Energy Saver's 32 ms grid")
        #expect(harness.rig.timer.armedDate == 32 * ms)
    }

    // MARK: Hidden

    @Test func aHiddenNodeAlignsToTheWholeUptimeSecondAndAVisibleOneIsFlexible() {
        let harness = DeadlineHarness()
        let hidden = harness.node(.hidden)
        let visible = harness.node(.visible)
        let hiddenDeadline = harness.deadline("hidden", alignment: .whenHidden(hidden))
        let visibleDeadline = harness.deadline("visible", alignment: .whenHidden(visible))
        var ran: [String] = []
        hiddenDeadline.schedule(after: .milliseconds(300)) { ran.append("hidden") }
        visibleDeadline.schedule(after: .milliseconds(300)) { ran.append("visible") }
        #expect(hiddenDeadline.plannedWake?.rule == .hidden)
        #expect(hiddenDeadline.plannedWake?.fire == .seconds(1))
        #expect(visibleDeadline.plannedWake?.rule == .flexible)
        #expect(visibleDeadline.plannedWake?.fire == .milliseconds(304))

        harness.rig.fire()
        harness.frame()
        #expect(ran == ["visible"], "the hidden deadline does not ride the visible fire")
        #expect(harness.rig.timer.armedDate == 1_000 * ms, "it waits for its 1 s boundary")
        harness.rig.fire()
        harness.frame()
        #expect(ran == ["visible", "hidden"])
    }

    @Test func boundariesAreOnUptimeAndSharedWithEveryQueueUser() {
        // The scheduler is made 123.456789 ms after the uptime origin: its grids must not start there.
        let harness = DeadlineHarness(start: 123_456_789)
        let node = harness.node(.hidden)
        let deadline = harness.deadline("hidden", alignment: .whenHidden(node))
        let log = RunLog()
        deadline.schedule(after: .milliseconds(300)) { log.ran.append("deadline") }
        AlignedWakeups(queue: harness.rig.queue).schedule(owner: "other", after: .milliseconds(700), placement: .hidden) {
            log.ran.append("other")
        }
        #expect(deadline.plannedWake?.fire == .seconds(1), "the whole uptime second, not creation + 1 s")
        #expect(harness.rig.timer.armedDate == 1_000 * ms)
        harness.rig.fire()
        harness.frame()
        #expect(log.ran == ["other", "deadline"], "the plain entry runs in the fire, the deadline's action in the frame")
        #expect(harness.rig.fires == 1, "a MainDeadline and another hidden entry due in the same second share one wake")
    }

    @Test func aOneShotDeadlineHiddenFiveMinutesStaysAtOneSecond() {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        harness.rig.uptime.now = 300_000 * ms
        let deadline = harness.deadline("one-shot", alignment: .whenHidden(node))
        deadline.schedule(after: .milliseconds(1_500)) {}
        #expect(deadline.plannedWake?.rule == .hidden)
        #expect(deadline.plannedWake?.fire == .seconds(302))
    }

    @Test func aRepeatingDeadlineHiddenFiveMinutesWakesEverySixtySeconds() {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        harness.rig.uptime.now = 10_000 * ms
        let early = harness.deadline("early", alignment: .whenHidden(node))
        early.start(every: .seconds(1)) {}
        #expect(early.plannedWake?.rule == .hidden, "hidden 11 s at its due time: 1 s alignment")
        early.cancel()

        harness.rig.uptime.now = 300_000 * ms
        let poll = harness.deadline("poll", workClass: .background, alignment: .whenHidden(node))
        var runs = 0
        poll.start(every: .seconds(1)) { runs += 1 }
        #expect(poll.plannedWake?.rule == .intensive)
        #expect(poll.plannedWake?.fire == .seconds(301), "no wake in the last minute: a 1 s-aligned wake is allowed")

        harness.rig.fire()
        harness.frame()
        #expect(runs == 1)
        #expect(poll.plannedWake?.fire == .seconds(360), "the next wake is on the minute")
        #expect(harness.rig.timer.armedDate == 360_000 * ms)

        harness.rig.fire()
        harness.frame()
        #expect(runs == 2)
        #expect(poll.plannedWake?.fire == .seconds(420))
        #expect(harness.rig.deadlines(of: "poll") == 2)
        #expect(harness.rig.fires == 2)
    }

    @Test func twoRepeatingDeadlinesOnOneNodeShareItsBudget() {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        harness.rig.uptime.now = 300_000 * ms
        let fast = harness.deadline("fast", workClass: .background, alignment: .whenHidden(node))
        let slow = harness.deadline("slow", workClass: .background, alignment: .whenHidden(node))
        var ran: [String] = []
        fast.start(every: .seconds(1)) { ran.append("fast") }
        harness.rig.uptime.now = 300_500 * ms
        slow.start(every: .seconds(6)) { ran.append("slow") }
        #expect(fast.plannedWake?.fire == .seconds(301))
        #expect(slow.plannedWake?.rule == .intensive)

        harness.rig.fire()
        harness.frame()
        #expect(ran == ["fast"])
        #expect(slow.plannedWake?.fire == .seconds(360), "the node spent its 1 s-aligned wake: the slow one waits")
        #expect(fast.plannedWake?.fire == .seconds(360))
        #expect(harness.rig.timer.armedDate == 360_000 * ms, "no other wake in the minute")

        harness.rig.fire()
        harness.frame()
        #expect(Set(ran.dropFirst()) == ["fast", "slow"], "both run in the node's one wake")
        #expect(harness.rig.fires == 2, "one 1 s-aligned wake, then the minute: never two in a minute")
        #expect(harness.rig.deadlines(of: "fast") == 2)
        #expect(harness.rig.deadlines(of: "slow") == 1)
    }

    @Test func aDeadlineScheduledFromItsOwnActionCountsAsRepeating() {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        harness.rig.uptime.now = 300_000 * ms
        let deadline = harness.deadline("self-arming", alignment: .whenHidden(node))
        deadline.schedule(after: .seconds(1)) { [weak deadline] in deadline?.schedule(after: .seconds(1)) {} }
        #expect(deadline.plannedWake?.rule == .hidden, "a first one-shot schedule is not repeating")
        harness.rig.fire()
        harness.frame()
        #expect(deadline.plannedWake?.rule == .intensive)
        #expect(deadline.plannedWake?.fire == .seconds(302), "no budget wake yet: one 1 s-aligned wake is allowed")
    }

    @Test func theIntensiveRuleAllowsOneAlignedWakeAMinute() {
        let last = 360_000 * ms
        #expect(TimerAlignment.intensiveFire(due: 362_200 * ms, lastWake: last) == 420_000 * ms)
        #expect(TimerAlignment.intensiveFire(due: 425_300 * ms, lastWake: last) == 426_000 * ms,
                "a minute after the last wake: the next 1 s boundary")
        #expect(TimerAlignment.intensiveFire(due: 10_300 * ms, lastWake: nil) == 11_000 * ms, "no wake yet")
    }

    // MARK: Exemptions

    @Test func recentMediaOrAShowingCaptureVoteDisablesAlignment() {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        let deadline = harness.deadline("media", alignment: .whenHidden(node))

        node.setMediaActive(true)
        deadline.schedule(after: .milliseconds(300)) {}
        #expect(deadline.plannedWake?.rule == .flexible, "playing media")
        node.setMediaActive(false)
        harness.rig.uptime.now += 29_000 * ms
        deadline.schedule(after: .milliseconds(300)) {}
        #expect(deadline.plannedWake?.rule == .flexible, "media 29 s ago")
        harness.rig.uptime.now += 1_000 * ms
        deadline.schedule(after: .milliseconds(300)) {}
        #expect(deadline.plannedWake?.rule == .hidden, "media 30 s ago")

        let screenshot = node.captureVote(reason: "test.screenshot", stayHidden: true)
        #expect(deadline.plannedWake?.rule == .hidden, "a stayHidden capture keeps the timers aligned")
        let mirror = node.captureVote(reason: "test.mirror", stayHidden: false)
        #expect(deadline.plannedWake?.rule == .flexible, "a capture vote that shows the node places the pending wake again")
        deadline.schedule(after: .milliseconds(300)) {}
        #expect(deadline.plannedWake?.rule == .flexible, "a capture vote")
        mirror.release()
        #expect(deadline.plannedWake?.rule == .hidden, "the vote's release aligns the pending wake again")
        screenshot.release()
    }

    @Test func mediaStartingReplansAPendingBudgetWakeAtOnce() {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        harness.rig.uptime.now = 300_000 * ms
        let poll = harness.deadline("poll", workClass: .background, alignment: .whenHidden(node))
        poll.start(every: .seconds(1)) {}
        harness.rig.fire()
        harness.frame()
        #expect(poll.plannedWake?.fire == .seconds(360), "a pending 60 s budget wake")

        node.setMediaActive(true)
        #expect(poll.plannedWake?.rule == .flexible)
        #expect(poll.plannedWake?.fire == .seconds(302), "due at 302 s, no longer held for the minute")
        #expect(harness.rig.timer.armedDate == 302_000 * ms)
    }

    @Test func aCaptureVoteReplansAPendingHiddenWake() {
        let harness = DeadlineHarness()
        let node = harness.node(.hidden)
        let deadline = harness.deadline("capture", alignment: .whenHidden(node))
        deadline.schedule(after: .milliseconds(300)) {}
        #expect(harness.rig.timer.armedDate == 1_000 * ms)
        let vote = node.captureVote(reason: "test.mirror", stayHidden: false)
        #expect(deadline.plannedWake?.fire == .milliseconds(304))
        #expect(harness.rig.timer.armedDate == 304 * ms)
        vote.release()
    }

    @Test func showingTheNodeReplansAPendingHiddenDeadline() {
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
        harness.rig.fire()
        harness.frame()
        #expect(ran == 1)
    }

    // MARK: Registry

    @Test func nextFireIsTheEarliestOfTheQueue() {
        let harness = DeadlineHarness()
        let hidden = harness.deadline("hidden", alignment: .whenHidden(harness.node(.hidden)))
        let flexible = harness.deadline("flexible")
        let precise = harness.deadline("precise", alignment: .precise)
        hidden.schedule(after: .milliseconds(300)) {}
        flexible.schedule(after: .milliseconds(500)) {}
        precise.schedule(after: .milliseconds(20)) {}
        #expect(harness.scheduler.nextFire == .milliseconds(20))
        #expect(harness.scheduler.nextFireNanos == 20 * ms, "the same instant on the uptime clock")
        #expect(harness.rig.queue.count == 3)

        precise.cancel()
        #expect(harness.scheduler.nextFire == .milliseconds(504))
        flexible.cancel()
        #expect(harness.scheduler.nextFire == .seconds(1))
        let other = AlignedWakeups(queue: harness.rig.queue).schedule(owner: "other", after: .milliseconds(100)) {}
        #expect(harness.scheduler.nextFire == .milliseconds(104), "every user of the queue counts")
        AlignedWakeups(queue: harness.rig.queue).cancel(other)
        hidden.cancel()
        #expect(harness.scheduler.nextFire == nil)
        #expect(harness.scheduler.nextFireNanos == nil)
        #expect(harness.rig.timer.armedDate == nil, "the timer is parked")
    }

    @Test func noWakeupsWhenEmpty() {
        let harness = DeadlineHarness()
        harness.rig.uptime.now = 600_000 * ms
        #expect(harness.rig.timer.arms.isEmpty)
        #expect(harness.scheduler.nextFire == nil)
        #expect(harness.rig.ledger.snapshot().isEmpty)

        let deadline = harness.deadline("cancelled")
        deadline.schedule(after: .milliseconds(100)) {}
        #expect(harness.rig.timer.armedDate != nil)
        deadline.cancel()
        #expect(harness.rig.timer.armedDate == nil, "the last cancel parks the timer")
        harness.rig.uptime.now += 600_000 * ms
        #expect(harness.rig.ledger.snapshot().isEmpty, "nothing woke")
    }

    @Test func cancellingAfterTheWakeDropsThePostedAction() {
        let harness = DeadlineHarness()
        let deadline = harness.deadline("late-cancel", workClass: .automation)
        var ran = 0
        deadline.schedule(after: .milliseconds(8)) { ran += 1 }
        harness.rig.fire()
        #expect(harness.work.postedCount(.automation) == 1)
        #expect(deadline.isScheduled, "scheduled until the action runs")
        deadline.cancel()
        harness.frame()
        #expect(ran == 0)
    }

    @Test func aReleasedDeadlineNeverRuns() {
        let harness = DeadlineHarness()
        var ran = 0
        var released: MainDeadline? = harness.deadline("released")
        released?.schedule(after: .milliseconds(48)) { ran += 1 }
        released = nil
        harness.rig.fire()
        harness.frame()
        #expect(ran == 0)
        #expect(harness.work.postedCount(.visible) == 0)
        #expect(harness.rig.queue.count == 0)
    }

    @Test func deadlinesDueTogetherShareOneWake() {
        let harness = DeadlineHarness()
        var ran: [String] = []
        let deadlines = (0..<5).map { harness.deadline("shared \($0)") }
        for (index, deadline) in deadlines.enumerated() {
            deadline.schedule(after: .milliseconds(17 + index)) { ran.append("shared \(index)") }
        }
        #expect(harness.scheduler.nextFire == .milliseconds(24))
        harness.rig.fire()
        harness.frame()
        #expect(ran == (0..<5).map { "shared \($0)" })
        #expect(harness.rig.fires == 1)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    // MARK: Arm census

    /// A deadline armed while its ledger's arm census records (startup-queue.py arms) leaves one
    /// record: its owner, the line that made it, the arms before its wake, and the wake.
    @Test func aDeadlineArmedDuringTheLaunchIsInTheArmCensus() throws {
        let harness = DeadlineHarness()
        let census = harness.rig.ledger.armCensus
        census.start(processStartNanos: 0)
        let deadline = harness.deadline("census")
        deadline.schedule(after: .milliseconds(20)) {}
        deadline.schedule(after: .milliseconds(30)) {}
        let untouched = harness.deadline("census.cancelled")
        untouched.schedule(after: .seconds(5)) {}
        untouched.cancel()
        #expect(census.snapshot().arms.map(\.firstFireNanos).allSatisfy { $0 == nil })

        harness.rig.fire()
        let arms = census.snapshot().arms
        #expect(arms.map(\.owner) == ["census", "census.cancelled"])
        #expect(arms.map(\.kind) == [.mainDeadline, .mainDeadline])
        #expect(arms.first?.site.description.contains("MainDeadlineTests.swift:") == true, "the harness line that made it")
        #expect(arms.first?.count == 2)
        #expect(arms.first?.firstFireNanos != nil, "the wake is the first fire, before the posted action runs")
        #expect(arms.last?.firstFireNanos == nil)
    }
    #endif
}

private let ms: UInt64 = 1_000_000

/// What ran, for actions the queue holds as `@Sendable`.
@MainActor
private final class RunLog {
    var ran: [String] = []
}

/// A deadline scheduler on WakeUpQueueRig's queue, a main-thread scheduler whose posts wait for hand-fired frames, and
/// a visibility tree on the rig's uptime.
@MainActor
private final class DeadlineHarness {
    let rig: WakeUpQueueRig
    let work: MainWorkScheduler
    let scheduler: MainDeadlineScheduler
    private let keeper: FrameClient
    private let budgetClock: FrameUptime
    private var frames: Double = 0
    private var nodes: [VisibilityNode] = []

    init(energy: EnergyPolicySource = EnergyPolicySource(), start: UInt64 = 0) {
        let rig = WakeUpQueueRig(energy: energy, start: start)
        let budgetClock = FrameUptime()
        self.rig = rig
        self.budgetClock = budgetClock
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: budgetClock.read),
                                             ledger: WakeupLedger()) { _ in DeadlineFakeLink() }
        self.work = work
        scheduler = MainDeadlineScheduler(work: work, queue: rig.queue)
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        self.keeper = keeper
        keeper.activate()
    }

    func deadline(_ owner: String, workClass: BudgetedWorkClass = .visible,
                  alignment: TimerAlignment = .flexible) -> MainDeadline {
        MainDeadline(owner: owner, workClass: workClass, alignment: alignment, scheduler: scheduler)
    }

    /// A root node on the rig's uptime, kept alive by the harness.
    func node(_ own: Visibility) -> VisibilityNode {
        let uptime = rig.uptime
        let node = VisibilityNode(root: "test.node", own: own, uptime: { .nanoseconds(Int64(uptime.now)) })
        nodes.append(node)
        return node
    }

    /// One display frame: posted actions run.
    func frame() {
        budgetClock.now += 17_000_000
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
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
