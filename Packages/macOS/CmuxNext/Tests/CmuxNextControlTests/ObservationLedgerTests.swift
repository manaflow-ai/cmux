#if DEBUG
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Testing

/// The observation ledger's per-owner counts and `debug.observations`.
@Suite struct ObservationLedgerTests {
    @Test func countsArePerOwner() throws {
        let ledger = ObservationLedger()
        let rows = ledger.owner("SidebarRow.status")
        let tasks = ledger.owner("TasksHostView")
        for _ in 0..<3 { rows.armed() }
        rows.disarmed()
        rows.evaluated(); rows.evaluated(); rows.applied()
        rows.showReread(nanos: 2_000_000); rows.showReread(nanos: 5_000_000)
        tasks.bodyEvaluated(hidden: false); tasks.bodyEvaluated(hidden: true)

        let entries = ledger.snapshot()
        let row = try #require(entries.first { $0.owner == "SidebarRow.status" })
        #expect(row == ObservationLedger.Entry(owner: "SidebarRow.status", armed: 2, arms: 3, evaluations: 2, applies: 1,
                                               showRereads: 2, showRereadNanos: 7_000_000, showRereadMaxNanos: 5_000_000,
                                               bodyEvaluations: 0, hiddenBodyEvaluations: 0))
        let task = try #require(entries.first { $0.owner == "TasksHostView" })
        #expect(task.bodyEvaluations == 2 && task.hiddenBodyEvaluations == 1 && task.evaluations == 0)
        #expect(entries.first?.owner == "SidebarRow.status", "the most evaluated first")
    }

    @Test func oneNameIsOneOwner() {
        let ledger = ObservationLedger()
        ledger.owner("Pane.title").evaluated()
        ledger.owner("Pane.title").evaluated()
        #expect(ledger.snapshot().map(\.evaluations) == [2])
    }

    @Test func resetZeroesCountsAndKeepsArmed() throws {
        let ledger = ObservationLedger()
        let owner = ledger.owner("Pane.title")
        owner.armed(); owner.evaluated(); owner.applied(); owner.showReread(nanos: 9); owner.bodyEvaluated(hidden: true)
        let taken = try #require(ledger.snapshot(resetting: true).first)
        #expect(taken.evaluations == 1 && taken.applies == 1 && taken.hiddenBodyEvaluations == 1, "the reset read returns the counts")
        let entry = try #require(ledger.snapshot().first)
        #expect(entry == ObservationLedger.Entry(owner: "Pane.title", armed: 1, arms: 0, evaluations: 0, applies: 0,
                                                 showRereads: 0, showRereadNanos: 0, showRereadMaxNanos: 0,
                                                 bodyEvaluations: 0, hiddenBodyEvaluations: 0))
    }

    @Test func recordingFromManyThreadsLosesNoCount() async throws {
        let ledger = ObservationLedger()
        let owner = ledger.owner("Burst")
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<1000 {
                        owner.evaluated()
                        owner.showReread(nanos: UInt64(worker * 1000 + index))
                    }
                }
            }
        }
        let entry = try #require(ledger.snapshot().first)
        #expect(entry.evaluations == 8000)
        #expect(entry.showRereads == 8000)
        #expect(entry.showRereadMaxNanos == 7999)
    }

    @Test func controlReportsOwnersTotalsAndResetsAfter() throws {
        let ledger = ObservationLedger()
        let rows = ledger.owner("SidebarRow.status")
        rows.armed(); rows.armed(); rows.evaluated(); rows.applied()
        rows.showReread(nanos: 1_500_000)
        ledger.owner("TasksHostView").bodyEvaluated(hidden: true)

        let report = ObservationsControl.report(["reset": .bool(true)], ledger: ledger)
        let totals = try #require(report.objectValue?["totals"]?.objectValue)
        #expect(totals["armed"]?.intValue == 2)
        #expect(totals["evaluations"]?.intValue == 1)
        #expect(totals["hidden_body_evaluations"]?.intValue == 1)
        let owners = try #require(report.objectValue?["owners"]?.arrayValue)
        let row = try #require(owners.first { $0.objectValue?["owner"]?.stringValue == "SidebarRow.status" }?.objectValue)
        #expect(row["applies"]?.intValue == 1)
        #expect(row["show_rereads"]?.intValue == 1)
        #expect(row["show_reread_ms"] == .number(1.5))

        let after = ObservationsControl.report([:], ledger: ledger)
        #expect(after.objectValue?["totals"]?.objectValue?["evaluations"]?.intValue == 0, "reset after the report")
        #expect(after.objectValue?["totals"]?.objectValue?["armed"]?.intValue == 2, "armed is state, not reset")
    }

    @Test func controlFiltersByOwnerPrefix() throws {
        let ledger = ObservationLedger()
        ledger.owner("SidebarRow.status").evaluated()
        ledger.owner("TasksHostView").evaluated()
        let report = ObservationsControl.report(["owner": .string("Sidebar")], ledger: ledger)
        let owners = try #require(report.objectValue?["owners"]?.arrayValue)
        #expect(owners.compactMap { $0.objectValue?["owner"]?.stringValue } == ["SidebarRow.status"])
    }

    @Test func filteredResetKeepsOtherOwnersCounts() throws {
        let ledger = ObservationLedger()
        ledger.owner("SidebarRow.status").evaluated()
        ledger.owner("TasksHostView").evaluated()
        ledger.owner("TasksHostView").bodyEvaluated(hidden: true)
        _ = ObservationsControl.report(["owner": .string("Sidebar"), "reset": .bool(true)], ledger: ledger)
        let entries = ledger.snapshot()
        #expect(entries.first { $0.owner == "SidebarRow.status" }?.evaluations == 0, "the reported owner is reset")
        let tasks = try #require(entries.first { $0.owner == "TasksHostView" })
        #expect(tasks.evaluations == 1 && tasks.hiddenBodyEvaluations == 1, "an owner outside the filter keeps its counts")
    }

    @Test func resetDuringRecordingLosesNoCount() async throws {
        let ledger = ObservationLedger()
        let owner = ledger.owner("Burst")
        let taken = await withTaskGroup(of: UInt64.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1000 { owner.evaluated() }
                    return 0
                }
            }
            group.addTask {
                var sum: UInt64 = 0
                for _ in 0..<200 { sum += ledger.snapshot(resetting: true).first?.evaluations ?? 0 }
                return sum
            }
            return await group.reduce(0, +)
        }
        let rest = try #require(ledger.snapshot().first).evaluations
        #expect(taken + rest == 8000, "every event is in exactly one report")
    }
}
#endif
