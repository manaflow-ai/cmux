#if os(iOS)
import Testing

@testable import CmuxMobileShellUI

/// The workspace list forwards bar safe-areas through
/// `additionalSafeAreaInsets`, assuming the surrounding chrome holds still
/// while the delta converges. A split-column transition can answer each write
/// with a geometry change inside the same CoreAnimation flush, looping layout
/// forever (100% main thread, the transaction never commits). The budget is
/// the loop breaker: convergent layouts fit comfortably inside one turn's
/// budget, and a feedback loop is starved after it.
struct ChromeInsetWriteBudgetTests {
    @Test func convergentLayoutFitsWithinOneTurn() {
        var budget = ChromeInsetWriteBudget()
        // The design expects one write, occasionally two (bar show + resize).
        #expect(budget.allowWrite())
        #expect(budget.allowWrite())
    }

    @Test func feedbackLoopIsStarvedAfterTheBudget() {
        var budget = ChromeInsetWriteBudget()
        for _ in 0..<ChromeInsetWriteBudget.writesPerTurn {
            #expect(budget.allowWrite())
        }
        // The wedge: layout re-dirties itself on every write, so the run-loop
        // turn never ends and no reset arrives. Every further write must be
        // refused, forever, or the flush never completes.
        for _ in 0..<1000 {
            #expect(!budget.allowWrite())
        }
    }

    @Test func resetRestoresTheFullBudgetForTheNextTurn() {
        var budget = ChromeInsetWriteBudget()
        while budget.allowWrite() {}
        budget.reset()
        for _ in 0..<ChromeInsetWriteBudget.writesPerTurn {
            #expect(budget.allowWrite())
        }
        #expect(!budget.allowWrite())
    }
}
#endif
