import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// The refresh-scaled budget and the budget turn (plans/cmux-next/chrome-parity/p06-scheduler.md
/// "Budget mechanics"): under the after-commit placement the class shares scale with interval / 16.7 ms, the pass
/// target is interval - 2 ms - the measured render, and the budgeted batch leaves the display tick for a turn of its
/// own after the tick's commit, whose work ends by the next vsync less the commit estimate. The in-tick placement
/// (feature `mainBudgetTurn` off) keeps the old path.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainFrameBudgetBudgetTurnTests {
    private static let hz120 = 1.0 / 120

    @Test func atOneHundredTwentyHertzTheVisibleShareIsAboutOnePointTwoFiveMilliseconds() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, placement: .afterCommit)
        budget.beginFrame(timestamp: 1, refreshInterval: Self.hz120)
        #expect(Self.near(budget.shares.visible, 1_250_000), "visible got \(budget.shares.visible) at 120 Hz")
        #expect(Self.near(budget.shares.automation, 500_000))
        #expect(Self.near(budget.shares.background, 250_000))
        #expect(Self.near(budget.shares.userBlocking, 1_750_000), "userBlocking's cap scales with its two shares")
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(budget.shares == budget.budgets, "60 Hz keeps the written shares")
        budget.beginFrame(timestamp: 3, refreshInterval: 1.0 / 30)
        #expect(budget.shares == budget.budgets, "a slower display never gets more than the 60 Hz shares")

        let inTick = MainFrameBudget(uptimeNanos: clock.read)
        inTick.beginFrame(timestamp: 1, refreshInterval: Self.hz120)
        #expect(inTick.shares.visible == .microseconds(2_500), "the in-tick placement keeps the fixed shares")
    }

    /// The pass target is the period less 2 ms of input and the measured render: at 120 Hz, a 5 ms render leaves
    /// 1.33 ms (six 0.25 ms requests, where the in-tick path's 8 ms target leaves 3 ms), and a 7 ms render leaves only
    /// each class's first task. Synthesized frames, so no deadline adds to the limit.
    @Test func thePassTargetIsTheIntervalLessTheInputReserveAndTheRender() {
        func requests(after render: UInt64?, placement: BudgetedBatchPlacement) -> Int {
            let clock = BudgetClock()
            let budget = MainFrameBudget(uptimeNanos: clock.read, placement: placement)
            let owner = budget.board.owner("workspace.move")
            budget.beginFrame(timestamp: nil, refreshInterval: Self.hz120)
            if let render { budget.noteRenderPass(nanos: render) }
            clock.advance(ms: 9)
            budget.beginFrame(timestamp: nil, refreshInterval: Self.hz120)
            var ran = 0
            while budget.mayRun(.automation) {
                budget.run(.automation, owner: owner) { clock.advance(ms: 0.25) }
                ran += 1
            }
            return ran
        }
        #expect(requests(after: nil, placement: .afterCommit) == 8, "no render: the 2 ms of scaled shares")
        #expect(requests(after: 5_000_000, placement: .afterCommit) == 6, "8.33 - 2 - 5 ms leaves 1.33 ms")
        #expect(requests(after: 7_000_000, placement: .afterCommit) == 1, "past the pass: the first task still runs")
        #expect(requests(after: 5_000_000, placement: .inTick) == 12, "the in-tick path: 8 - 5 ms leaves 3 ms")
    }

    /// The tick turn holds no budgeted task: the batch runs in the turn the tick asks for after its commit, ticks
    /// before that turn ask once, and the turn meter reports a tick turn and a budget turn. The in-tick placement
    /// runs the batch in the tick and reports it there.
    @Test func theBudgetedBatchRunsInItsOwnTurnAfterTheTicksCommit() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, placement: .afterCommit)
        var budgetTurns: [@MainActor () -> Void] = []
        let work = MainWorkScheduler.testing(budget: budget, mediaTime: clock.media, budgetTurns: { budgetTurns.append($0) }) { _ in
            FakeFrameLink()
        }
        let owner = budget.board.owner("workspace.move")
        var ran = 0
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, budget in
            if budget.mayRun(.automation) { budget.run(.automation, owner: owner) { ran += 1 } }
            return true
        }
        batch.activate()
        let turns = budget.turns
        turns.loopWoke()
        work.frameDidFire(timestamp: clock.media(), refreshInterval: Self.hz120)
        turns.loopWillWait()
        turns.loopDidRender()
        #expect(ran == 0, "the tick ran a budgeted task")
        #expect(budgetTurns.count == 1, "the tick asked for \(budgetTurns.count) budget turns")
        clock.advance(ms: 1)
        turns.loopWoke()
        for turn in budgetTurns { turn() }
        turns.loopWillWait()
        turns.loopDidRender()
        #expect(ran == 1, "the budget turn did not run the batch")
        let snapshot = turns.snapshot()
        #expect(snapshot.tickTurns.count == 1)
        #expect(snapshot.tickTurnsWithBudgetedTasks == 0)
        #expect(snapshot.budgetTurns.count == 1)
        #expect(budget.budgetTurnStats.turns == 1)

        budgetTurns.removeAll()
        clock.advance(ms: 8)
        work.frameDidFire(timestamp: clock.media(), refreshInterval: Self.hz120)
        clock.advance(ms: 8.4)
        work.frameDidFire(timestamp: clock.media(), refreshInterval: Self.hz120)
        #expect(budgetTurns.count == 1, "two ticks before the turn ran asked for \(budgetTurns.count) turns")
        batch.deactivate()
    }

    @Test func theInTickPlacementRunsTheBatchInTheTick() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        var budgetTurns: [@MainActor () -> Void] = []
        let work = MainWorkScheduler.testing(budget: budget, mediaTime: clock.media, budgetTurns: { budgetTurns.append($0) }) { _ in
            FakeFrameLink()
        }
        let owner = budget.board.owner("workspace.move")
        var ran = 0
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, budget in
            if budget.mayRun(.automation) { budget.run(.automation, owner: owner) { ran += 1 } }
            return true
        }
        batch.activate()
        budget.turns.loopWoke()
        work.frameDidFire(timestamp: clock.media(), refreshInterval: Self.hz120)
        budget.turns.loopWillWait()
        budget.turns.loopDidRender()
        #expect(ran == 1)
        #expect(budgetTurns.isEmpty)
        #expect(budget.turns.snapshot().tickTurnsWithBudgetedTasks == 1)
        #expect(budget.turns.snapshot().budgetTurns.count == 0)
        batch.deactivate()
    }

    /// The budget turn's work ends by the next vsync less the commit estimate: at 120 Hz with 3 ms commits, a turn
    /// that starts 2 ms after the tick runs its 2 ms of scaled shares (four 0.5 ms requests) and ends before
    /// 5.33 ms; one that starts 6 ms after the tick (its tick's commit ran long) runs only its first task, which
    /// ends past the deadline and is counted.
    @Test func theBudgetTurnEndsBeforeItsDeadline() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, placement: .afterCommit)
        var budgetTurns: [@MainActor () -> Void] = []
        let work = MainWorkScheduler.testing(budget: budget, mediaTime: clock.media, budgetTurns: { budgetTurns.append($0) }) { _ in
            FakeFrameLink()
        }
        for _ in 0..<32 {
            budget.beginFrame(timestamp: clock.media(), refreshInterval: Self.hz120)
            budget.noteRenderPass(nanos: 3_000_000)
            clock.advance(ms: 1000.0 / 120)
        }
        let owner = budget.board.owner("workspace.move")
        var ran = 0
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, budget in
            while budget.mayRun(.automation) {
                budget.run(.automation, owner: owner) { clock.advance(ms: 0.5) }
                ran += 1
            }
            return true
        }
        batch.activate()
        func frame(tickCommitMs: Double) {
            budgetTurns.removeAll()
            ran = 0
            work.frameDidFire(timestamp: clock.media(), refreshInterval: Self.hz120)
            clock.advance(ms: tickCommitMs)
            for turn in budgetTurns { turn() }
            clock.advance(ms: 1000.0 / 120 - tickCommitMs - Double(ran) * 0.5)
        }
        frame(tickCommitMs: 2)
        #expect(ran == 4, "\(ran) requests ran in the budget turn")
        #expect(budget.budgetTurnStats.turns == 1)
        #expect(budget.budgetTurnStats.pastDeadline == 0, "the turn ended past the next vsync less the commit")
        frame(tickCommitMs: 6)
        #expect(ran == 1, "a turn that starts past its deadline runs only its first task")
        #expect(budget.budgetTurnStats.pastDeadline == 1)
        #expect(budget.budgetTurnStats.maxOverrunNanos > 0)
        batch.deactivate()
    }

    /// An automation post whose next turn comes while a tick's batch waits for its own turn runs in that turn,
    /// right after the tick's commit, not in the tick's turn.
    @Test func aPostedTurnWhileTheBatchWaitsRunsInTheBudgetTurn() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, placement: .afterCommit)
        var postedTurns: [@MainActor () -> Void] = []
        var budgetTurns: [@MainActor () -> Void] = []
        let work = MainWorkScheduler.testing(budget: budget, mediaTime: clock.media, performTurn: { postedTurns.append($0) },
                                             budgetTurns: { budgetTurns.append($0) }) { _ in FakeFrameLink() }
        let keeper = FrameClient(owner: "test.keeper", budgeted: .visible, on: work) { _, _ in true }
        keeper.activate()
        work.frameDidFire(timestamp: clock.media(), refreshInterval: Self.hz120)
        #expect(budgetTurns.count == 1)
        var ran = false
        work.post(.automation, owner: "cli.request") { ran = true }
        for turn in postedTurns { turn() }
        #expect(!ran, "the posted turn ran budgeted work while the tick's batch waited")
        for turn in budgetTurns { turn() }
        #expect(ran, "the budget turn did not run the posted work")
        keeper.deactivate()
    }

    /// `debug.main_budget` reports the placement, the budget turns and both turn kinds.
    @Test func theReportHasBothTurnKinds() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, placement: .afterCommit)
        let parts = budget.reportParts
        #expect(parts.fields["placement"] == .string("after_commit"))
        #expect(parts.fields["budget_turns"] != nil)
        let turnFields = parts.turns.reportFields
        #expect(turnFields["tick_turn_ms"] != nil)
        #expect(turnFields["budget_turn_ms"] != nil)
        #expect(MainFrameBudget(uptimeNanos: clock.read).reportParts.fields["placement"] == .string("in_tick"))
    }

    private static func near(_ share: Duration, _ nanos: UInt64) -> Bool {
        let value = MainFrameBudget.nanos(share)
        return (value > nanos ? value - nanos : nanos - value) < 1_000
    }
}
