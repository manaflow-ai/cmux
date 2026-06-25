import Foundation
import Testing

@testable import CmuxTaskManager

@Suite("Task Manager row, sort, and formatting")
struct RowSortAndFormatTests {
    private func row(
        id: String,
        level: Int = 0,
        title: String = "row",
        cpu: Double = 0,
        memoryBytes: Int64 = 0,
        processCount: Int = 0,
        processId: Int? = nil,
        rootProcessIds: [Int] = [],
        foregroundProcessGroupIds: [Int] = []
    ) -> CmuxTaskManagerRow {
        CmuxTaskManagerRow(
            id: id,
            kind: .process,
            level: level,
            title: title,
            detail: "",
            resources: CmuxTaskManagerResources(
                cpuPercent: cpu,
                residentBytes: memoryBytes,
                memoryBytes: memoryBytes,
                processCount: processCount
            ),
            isDimmed: false,
            workspaceId: nil,
            surfaceId: nil,
            terminalSurfaceId: nil,
            processId: processId,
            rootProcessIds: rootProcessIds,
            foregroundProcessGroupIds: foregroundProcessGroupIds,
            agentAssetName: nil
        )
    }

    @Test("init canonicalizes the PID arrays (deduped, ascending)")
    func rowCanonicalizesPIDs() {
        let r = row(id: "a", rootProcessIds: [9, 1, 9, 4], foregroundProcessGroupIds: [5, 5, 2])
        #expect(r.rootProcessIds == [1, 4, 9])
        #expect(r.foregroundProcessGroupIds == [2, 5])
    }

    @Test("killableProcessIds excludes PID 1 and the current process")
    func killableExcludesUnsafe() {
        let r = CmuxTaskManagerRow(
            id: "a", kind: .process, level: 0, title: "t", detail: "",
            resources: CmuxTaskManagerResources(cpuPercent: 0, residentBytes: 0, processCount: 1, processIds: [1, 42]),
            isDimmed: false, workspaceId: nil, surfaceId: nil, terminalSurfaceId: nil,
            processId: Int(getpid()), rootProcessIds: [], foregroundProcessGroupIds: [], agentAssetName: nil
        )
        #expect(r.killableProcessIds == [42])
        #expect(r.canKillProcess)
    }

    @Test("withAgentAssetName returns self when unchanged, a copy when changed")
    func withAgentAssetName() {
        let base = row(id: "a")
        #expect(base.withAgentAssetName(nil) == base)
        let updated = base.withAgentAssetName("claude")
        #expect(updated.agentAssetName == "claude")
        #expect(updated != base)
    }

    @Test("sortedRows orders children within each parent and keeps the tree intact")
    func hierarchicalSort() {
        // parent P with children high-cpu and low-cpu (in reverse order),
        // sorted by CPU descending should put high-cpu before low-cpu.
        let rows = [
            row(id: "P", level: 0, title: "parent", cpu: 0),
            row(id: "low", level: 1, title: "low", cpu: 1),
            row(id: "high", level: 1, title: "high", cpu: 99),
        ]
        let order = CmuxTaskManagerSortOrder(column: .cpu, direction: .descending)
        let sorted = order.sortedRows(rows).map(\.id)
        #expect(sorted == ["P", "high", "low"])
    }

    @Test("toggled flips direction on the active column, switches to defaults otherwise")
    func toggleSemantics() {
        let cpuDesc = CmuxTaskManagerSortOrder.defaultOrder
        #expect(cpuDesc == CmuxTaskManagerSortOrder(column: .cpu, direction: .descending))
        #expect(cpuDesc.toggled(for: .cpu) == CmuxTaskManagerSortOrder(column: .cpu, direction: .ascending))
        // name defaults to ascending when first selected.
        #expect(cpuDesc.toggled(for: .name) == CmuxTaskManagerSortOrder(column: .name, direction: .ascending))
    }

    @Test("Double.taskManagerCPUString clamps at zero and shows one decimal")
    func cpuFormatting() {
        #expect((12.34).taskManagerCPUString == "12.3%")
        #expect((-5.0).taskManagerCPUString == "0.0%")
    }

    @Test("Int64.taskManagerByteString uses binary units, whole bytes, one decimal above")
    func byteFormatting() {
        #expect(Int64(512).taskManagerByteString == "512 B")
        #expect(Int64(1536).taskManagerByteString == "1.5 KB")
        #expect(Int64(-1).taskManagerByteString == "0 B")
    }

    @Test("CmuxTaskManagerDateFormatting round-trips an ISO-8601 timestamp")
    func dateParsing() {
        let formatter = CmuxTaskManagerDateFormatting()
        #expect(formatter.date(fromISO8601: nil) == nil)
        #expect(formatter.date(fromISO8601: "not-a-date") == nil)
        let parsed = formatter.date(fromISO8601: "2026-06-24T00:00:00Z")
        #expect(parsed != nil)
    }
}
