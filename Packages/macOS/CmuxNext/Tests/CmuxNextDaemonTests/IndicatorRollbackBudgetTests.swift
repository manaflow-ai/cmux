@testable import CmuxNextDaemon
import Foundation
import Testing

/// The native indicator budget (cmuxterm-hq docs/handbook/perf-footguns.md, class 1): an optimistic
/// tab indicator write rolled back over and over on one tab warns once, naming the fix; a rollback
/// now and then (a daemon that restarts once) does not.
@MainActor
struct IndicatorRollbackBudgetTests {
    @Test func aRollbackPerKeyWarnsOnce() {
        let budget = IndicatorRollbackBudget()
        let start = ContinuousClock.now
        for key in 0..<20 { budget.rolledBack("notification-read", tab: "t1", at: start + .milliseconds(150 * key)) }
        #expect(budget.warnings.count == 1)
        #expect(budget.warnings.first?.contains("send it once per state") == true)
    }

    @Test func aRareRollbackDoesNotWarn() {
        let budget = IndicatorRollbackBudget()
        let start = ContinuousClock.now
        for minute in 0..<10 { budget.rolledBack("notification-read", tab: "t1", at: start + .seconds(60 * minute)) }
        #expect(budget.warnings.isEmpty)
    }
}
