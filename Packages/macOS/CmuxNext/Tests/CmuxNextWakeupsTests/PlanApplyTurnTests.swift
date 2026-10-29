@testable import CmuxNextWakeups
import Testing

/// A layout plan's apply is open from the apply until its run loop turn ends (its before-waiting
/// commit): the in-process CEF pump starts no slice inside it. The test drives the
/// turn meter's run-loop callouts by hand.
@MainActor
@Suite struct PlanApplyTurnTests {
    @Test func anApplyIsOpenUntilItsTurnEnds() {
        let turns = MainTurnMeter()
        let plans = PlanApplyTurn(turns: turns)
        turns.loopWoke()
        #expect(!plans.isOpen, "no apply yet")
        plans.noteApplied()
        #expect(plans.isOpen)
        turns.loopWillWait()
        turns.loopDidRender()
        turns.loopWoke()
        #expect(!plans.isOpen, "the next turn: the apply committed")
        plans.noteApplied()
        #expect(plans.isOpen, "a motion frame applies again in its own turn")
    }

    @Test func theSchedulerOwnsOneOnItsBudgetsMeter() {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        work.budget.turns.loopWoke()
        work.planApplies.noteApplied()
        #expect(work.planApplies.isOpen)
        work.budget.turns.loopDidRender()
        work.budget.turns.loopWoke()
        #expect(!work.planApplies.isOpen)
    }
}
