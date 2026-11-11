import CmuxNextWakeups
import Foundation
import Testing

/// The always-on cost of one scheduled main-thread task in ``MainFrameBudget/run(_:owner:_:)``, in nanoseconds: two
/// clock reads, the board's publish and the per-owner record (hot path `main-task-record`: the owner's slot lookup,
/// one bucket and a few stores). Three shapes: 4 owners interned first, 4 owners interned after 1500 other names (the
/// app: each bound action takes a board number before the first observation site runs), and 400 owners in turn (the
/// app's observation sites). A measurement, not a gate: run it in a Release build before and after a change of the
/// record and quote the lines.
///
/// ```
/// CMUX_MAIN_TASK_RECORD_BENCH=1 swift test -c release --filter MainTaskRecordBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_MAIN_TASK_RECORD_BENCH"] == "1"))
struct MainTaskRecordBench {
    private static let runs = 2_000_000

    /// Nanoseconds per empty frame-class task of `owners` in turn.
    private static func taskNanos(_ budget: MainFrameBudget, _ owners: [MainTaskOwner]) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var index = 0
        for _ in 0..<runs {
            budget.run(.frame, owner: owners[index]) {}
            index += 1
            if index == owners.count { index = 0 }
        }
        return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(runs)
    }

    @Test func alwaysOnCostPerTask() {
        let first = MainFrameBudget()
        let firstOwners = (0..<4).map { first.board.owner("owner \($0)") }
        _ = Self.taskNanos(first, firstOwners) // warm
        let early = Self.taskNanos(first, firstOwners)

        let late = MainFrameBudget()
        for action in 0..<1_500 { _ = late.board.internOwner("action.\(action)") }
        let lateOwners = (0..<4).map { late.board.owner("site \($0)") }
        _ = Self.taskNanos(late, lateOwners)
        let afterActions = Self.taskNanos(late, lateOwners)

        let many = MainFrameBudget()
        for action in 0..<1_500 { _ = many.board.internOwner("action.\(action)") }
        let manyOwners = (0..<400).map { many.board.owner("site \($0)") }
        _ = Self.taskNanos(many, manyOwners)
        let sites = Self.taskNanos(many, manyOwners)

        let named = many.ownerTimes.filter { $0.owner != MainFrameBudget.overflowOwnerName }.count
        print(String(format: "MAIN-TASK-RECORD-BENCH ns_per_task early_owners=%.1f owners_after_1500_names=%.1f 400_owners_in_turn=%.1f named_rows_of_400=%d",
                     early, afterActions, sites, named))
    }
}
