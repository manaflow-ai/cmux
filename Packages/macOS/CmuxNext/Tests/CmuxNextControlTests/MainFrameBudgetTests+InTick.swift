import CmuxNextWakeups
import Testing

/// A frame's budgeted batch runs in the display tick (plans/cmux-next/chrome-parity/p06-scheduler.md "Budget
/// mechanics"): the tick's turn holds the budgeted task.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainFrameBudgetInTickTests {
    @Test func theBudgetedBatchRunsInTheTick() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let work = MainWorkScheduler.testing(budget: budget, mediaTime: clock.media) { _ in FakeFrameLink() }
        let owner = budget.board.owner("workspace.move")
        var ran = 0
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, budget in
            if budget.mayRun(.automation) { budget.run(.automation, owner: owner) { ran += 1 } }
            return true
        }
        batch.activate()
        budget.turns.loopWoke()
        work.frameDidFire(timestamp: clock.media(), refreshInterval: 1.0 / 120)
        budget.turns.loopWillWait()
        budget.turns.loopDidRender()
        #expect(ran == 1)
        #expect(budget.turns.snapshot().tickTurnsWithBudgetedTasks == 1)
        batch.deactivate()
    }
}
