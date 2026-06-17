import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("WorkspaceReorderPlanner")
struct WorkspaceReorderPlannerTests {
    private let planner = WorkspaceReorderPlanner()

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    @Test func planMovesRequestedUnpinnedWorkspacesAheadOfUnmentionedOnes() {
        let all = ids(3)
        let current = all.map { WorkspaceOrderSnapshot(id: $0, isPinned: false) }

        let result = planner.batchReorderPlan(orderedWorkspaceIds: [all[2], all[0]], current: current)

        guard case .success(let plan) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(plan == [
            WorkspaceReorderPlanItem(workspaceId: all[2], fromIndex: 2, toIndex: 0),
            WorkspaceReorderPlanItem(workspaceId: all[0], fromIndex: 0, toIndex: 1),
        ])
        #expect(planner.batchReorderFinalIds(orderedWorkspaceIds: [all[2], all[0]], current: current) == [all[2], all[0], all[1]])
    }

    @Test func planKeepsPinnedWorkspacesAheadOfUnpinned() {
        let pinnedA = UUID()
        let pinnedB = UUID()
        let unpinnedA = UUID()
        let unpinnedB = UUID()
        let current = [
            WorkspaceOrderSnapshot(id: pinnedA, isPinned: true),
            WorkspaceOrderSnapshot(id: pinnedB, isPinned: true),
            WorkspaceOrderSnapshot(id: unpinnedA, isPinned: false),
            WorkspaceOrderSnapshot(id: unpinnedB, isPinned: false),
        ]

        // Request interleaves an unpinned ahead of a pinned; the final order
        // still puts every pinned id ahead of every unpinned id.
        let finalIds = planner.batchReorderFinalIds(
            orderedWorkspaceIds: [unpinnedB, pinnedB],
            current: current
        )
        #expect(finalIds == [pinnedB, pinnedA, unpinnedB, unpinnedA])
    }

    @Test func planRejectsDuplicatesBeforeUnknownWorkspaces() {
        let known = UUID()
        let unknown = UUID()
        let current = [WorkspaceOrderSnapshot(id: known, isPinned: false)]

        let duplicate = planner.batchReorderPlan(
            orderedWorkspaceIds: [known, known, unknown],
            current: current
        )
        #expect(duplicate == .failure(.duplicateWorkspace(known)))

        let missing = planner.batchReorderPlan(orderedWorkspaceIds: [unknown], current: current)
        #expect(missing == .failure(.workspaceNotFound(unknown)))
    }

    @Test func emptyRequestPlansNoMoves() {
        let all = ids(2)
        let current = all.map { WorkspaceOrderSnapshot(id: $0, isPinned: false) }

        let result = planner.batchReorderPlan(orderedWorkspaceIds: [], current: current)

        #expect(result == .success([]))
        #expect(planner.batchReorderFinalIds(orderedWorkspaceIds: [], current: current) == all)
    }
}
