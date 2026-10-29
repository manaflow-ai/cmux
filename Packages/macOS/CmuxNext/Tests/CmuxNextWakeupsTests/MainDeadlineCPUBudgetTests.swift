@testable import CmuxNextWakeups
import Testing

/// A `.whenHidden` MainDeadline's action is charged to its scheduler's CPU-time budget
/// (plans/cmux-next/chrome-parity/p06-scheduler.md): a hidden node's repeating 20 ms action is
/// held to 10 ms/s by placing its wake again for the first aligned wake with budget, while a visible node's action
/// and an exempt one (media) are never charged or deferred. The wake queue and the budget share one fake uptime.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainDeadlineCPUBudgetTests {
    @Test func aHiddenRepeatingDeadlineIsHeldToTenMillisecondsPerSecond() {
        let harness = BudgetDeadlineHarness()
        let node = harness.node(.hidden)
        let deadline = MainDeadline(owner: "Tab.poll", workClass: .background, alignment: .whenHidden(node),
                                    scheduler: harness.scheduler)
        var runs = 0
        // Every 500 ms, on the 1 s hidden grid: one 20 ms action each second (20 ms/s) without the budget.
        deadline.start(every: .milliseconds(500)) { [uptime = harness.rig.uptime] in
            uptime.now += 20 * ms
            runs += 1
        }
        // 100 wakes stay under the 5 minutes after which a repeating hidden deadline moves to the minute grid.
        for _ in 0 ..< 100 {
            harness.rig.fire()
            harness.frame()
        }
        let elapsed = harness.rig.uptime.now / 1_000_000_000 + 1
        let pool = harness.work.hiddenBudget
        #expect(pool.stats.hiddenRuns == runs)
        #expect(pool.stats.charged <= .milliseconds(100 + 10 * Int64(elapsed) + 20),
                "never more than the cap plus 10 ms/s plus one action (\(runs) runs in \(elapsed) s)")
        #expect(runs < 100, "some wakes were deferred for budget")
        #expect(runs * 4 >= Int(elapsed), "it still runs on the wakes that have budget: \(runs) in \(elapsed) s")
        #expect(deadline.isScheduled, "a deferred repeating deadline stays scheduled")
        #expect(deadline.plannedWake?.rule == .hidden)
    }

    @Test func aVisibleNodesDeadlineIsNeverChargedOrDeferred() {
        let harness = BudgetDeadlineHarness()
        harness.work.hiddenBudget.record(.hidden, ran: .seconds(1))
        let before = harness.work.hiddenBudget.stats
        let node = harness.node(.visible)
        let deadline = MainDeadline(owner: "Tab.poll", workClass: .background, alignment: .whenHidden(node),
                                    scheduler: harness.scheduler)
        var runs = 0
        deadline.start(every: .seconds(1)) { [uptime = harness.rig.uptime] in
            uptime.now += 20 * ms
            runs += 1
        }
        for _ in 0 ..< 20 {
            harness.rig.fire()
            harness.frame()
        }
        #expect(runs == 20, "every wake runs the action")
        #expect(harness.work.hiddenBudget.stats == before, "visible work is never charged")
    }

    @Test func anExemptNodesDeadlineIsNeverDeferred() {
        let harness = BudgetDeadlineHarness()
        harness.work.hiddenBudget.record(.hidden, ran: .seconds(1))
        let before = harness.work.hiddenBudget.stats
        let node = harness.node(.hidden)
        node.setMediaActive(true)
        let deadline = MainDeadline(owner: "Media.poll", workClass: .background, alignment: .whenHidden(node),
                                    scheduler: harness.scheduler)
        var runs = 0
        deadline.schedule(after: .milliseconds(300)) { runs += 1 }
        harness.rig.fire()
        harness.frame()
        #expect(runs == 1, "media exempts the node: the budget in debt does not defer it")
        #expect(harness.work.hiddenBudget.stats == before, "exempt work is never charged")
    }

    /// A deadline deferred for budget runs at once when its node shows: visible work never waits.
    @Test func aDeferredDeadlineRunsWhenItsNodeShows() {
        let harness = BudgetDeadlineHarness()
        harness.work.hiddenBudget.record(.hidden, ran: .seconds(1))
        let node = harness.node(.hidden)
        let deadline = MainDeadline(owner: "Tab.poll", workClass: .background, alignment: .whenHidden(node),
                                    scheduler: harness.scheduler)
        var runs = 0
        deadline.schedule(after: .milliseconds(300)) { runs += 1 }
        harness.rig.fire()
        harness.frame()
        #expect(runs == 0, "the budget in debt holds the hidden action")
        #expect(deadline.isScheduled && deadline.plannedWake?.rule == .hidden, "its wake is placed again")
        #expect((deadline.plannedWake?.fire ?? .zero) > .seconds(30), "for when the budget is back")
        node.set(.visible)
        #expect(deadline.plannedWake?.rule == .flexible)
        #expect((deadline.plannedWake?.fire ?? .seconds(999)) < .seconds(3), "back to its own due instant")
        harness.fireAtNow()
        harness.frame()
        #expect(runs == 1)
    }
}

private let ms: UInt64 = 1_000_000

/// A deadline scheduler on WakeUpQueueRig's queue and a main-thread scheduler whose budget (and so its hidden
/// budget) reads the rig's uptime; posts run at hand-fired frames, each 17 ms of uptime.
@MainActor
private final class BudgetDeadlineHarness {
    let rig: WakeUpQueueRig
    let work: MainWorkScheduler
    let scheduler: MainDeadlineScheduler
    private let keeper: FrameClient
    private var frames: Double = 0
    private var nodes: [VisibilityNode] = []

    init() {
        let rig = WakeUpQueueRig(start: 1_000_000_000)
        self.rig = rig
        let uptime = rig.uptime
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { uptime.now }),
                                             ledger: WakeupLedger()) { _ in BudgetDeadlineFakeLink() }
        self.work = work
        scheduler = MainDeadlineScheduler(work: work, queue: rig.queue)
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        self.keeper = keeper
        keeper.activate()
    }

    /// A root node on the rig's uptime, kept alive by the harness.
    func node(_ own: Visibility) -> VisibilityNode {
        let uptime = rig.uptime
        let node = VisibilityNode(root: "test.node", own: own, uptime: { .nanoseconds(Int64(uptime.now)) })
        nodes.append(node)
        return node
    }

    /// Fires the queue at the current uptime: what is due by now runs.
    func fireAtNow() {
        rig.timer.fired()
        rig.queue.fire()
    }

    /// One display frame, 17 ms of uptime: posted actions run.
    func frame() {
        rig.uptime.now += 17 * ms
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
    }
}

@MainActor
private final class BudgetDeadlineFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
