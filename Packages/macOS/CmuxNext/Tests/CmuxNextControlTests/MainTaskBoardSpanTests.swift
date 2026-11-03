@testable import CmuxNextControl
import CmuxNextWakeups
import CoreFoundation
import Darwin
import Foundation
import Testing

/// A person's action as a span on the main-thread board (PL-instant's per-action budget monitor):
/// lock-free to mark, and the watchdog samples an action that runs past its budget and records it
/// with the action's id and a stack.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainTaskBoardSpanTests {
    @MainActor
    @Test func aSlowActionSpanGetsAnOverBudgetRecordWithItsOwnerAndAStack() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false))
        let board = MainTaskBoard()
        watchdog.start()
        defer { watchdog.stop() }
        watchdog.attach(board: board, recordTaskBudgets: true)
        let owner = board.internOwner("newWindow")
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            let token = board.beginSpan(.input, owner: owner, budgetNanos: 10_000_000, startNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            spinForTestAction(milliseconds: 40)
            board.endSpan(token, nowNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        let record = try #require(watchdog.overBudget.records().first, "no over-budget record for a 40 ms action with a 10 ms budget")
        #expect(record.kind == .overBudget)
        #expect(record.details["task_owner"] == .string("newWindow"))
        #expect(record.details["task_class"] == .string("input"))
        #expect(record.duration >= .milliseconds(40))
        #expect(!record.addresses.isEmpty, "the stack sampled when the action crossed its budget")
        #expect(record.frames.contains { $0.symbol?.contains("spinForTestAction") == true },
                "frames: \(record.frames.prefix(8).map(\.description))")
        #expect(board.running == nil, "the span put back what it covered (nothing)")
    }

    @MainActor
    @Test func aSpanInsideAScheduledTaskPutsTheTaskBack() {
        let budget = MainFrameBudget()
        let owner = budget.board.internOwner("tab.focus")
        var during: MainTaskBoard.Task?
        var after: MainTaskBoard.Task?
        budget.run(.automation, owner: budget.board.owner("Control.frames")) {
            let token = budget.board.beginSpan(.input, owner: owner, budgetNanos: 10_000_000, startNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            during = budget.board.running
            budget.board.endSpan(token, nowNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            after = budget.board.running
        }
        #expect(during?.owner == "tab.focus")
        #expect(after?.owner == "Control.frames")
    }

    /// Marking an action costs a few atomic stores: printed in ns per begin/end pair, bounded far
    /// above what atomics cost so a loaded runner never fails it, far below what a lock or an
    /// allocation per action would make it.
    @MainActor
    @Test func beginAndEndOfASpanCostNanoseconds() {
        let board = MainTaskBoard()
        let owner = board.internOwner("terminal.key")
        let count = 200_000
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<count {
            let token = board.beginSpan(.input, owner: owner, budgetNanos: 10_000_000, startNanos: start)
            board.endSpan(token, nowNanos: start)
        }
        let perPair = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(count)
        print("MainTaskBoard span begin+end: \(String(format: "%.1f", perPair)) ns")
        #expect(perPair < 2_000)
    }
}

/// Busy-waits on the main thread so the watchdog's stack names this frame.
@inline(never)
func spinForTestAction(milliseconds: Int) {
    let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(milliseconds) * 1_000_000
    while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {}
}
