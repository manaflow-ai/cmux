import Foundation
import Testing
@testable import CmuxWorkspaces

/// Coverage for folding an agent's reported task list into the workspace
/// checklist (https://github.com/manaflow-ai/cmux/issues/8960).
@Suite struct WorkspaceAgentChecklistSyncTests {
    private let mine = "workstream-A"
    private let theirs = "workstream-B"

    private func task(
        _ taskId: String,
        _ text: String,
        _ state: WorkspaceChecklistItem.State = .pending,
        workstreamId: String? = nil,
        id: UUID = UUID()
    ) -> WorkspaceAgentChecklistTask {
        WorkspaceAgentChecklistTask(
            id: id,
            ref: WorkspaceAgentTaskRef(workstreamId: workstreamId ?? mine, taskId: taskId),
            text: text,
            state: state
        )
    }

    private func agentRow(
        _ taskId: String,
        _ text: String,
        _ state: WorkspaceChecklistItem.State = .pending,
        workstreamId: String? = nil,
        id: UUID = UUID()
    ) -> WorkspaceChecklistItem {
        WorkspaceChecklistItem(
            id: id,
            text: text,
            state: state,
            origin: .agent,
            agentTaskRef: WorkspaceAgentTaskRef(workstreamId: workstreamId ?? mine, taskId: taskId)
        )
    }

    @Test func agentTasksAppendAfterRowsItDoesNotOwn() {
        let userItem = WorkspaceChecklistItem(text: "mine", state: .completed, origin: .user)
        let a = task("1", "plan", .completed), b = task("2", "build", .inProgress)
        let items = workspaceAgentChecklistReplacement(
            existing: [userItem],
            agentTasks: [a, b],
            workstreamId: mine
        )
        #expect(items?.map(\.text) == ["mine", "plan", "build"])
        #expect(items?.map(\.id) == [userItem.id, a.id, b.id])
        #expect(items?.map(\.state) == [.completed, .completed, .inProgress])
        #expect(items?.map(\.origin) == [.user, .agent, .agent])
        #expect(items?.last?.agentTaskRef == b.ref)
    }

    @Test func stalePreviouslyOwnedRowsAreRetired() {
        let keptId = UUID()
        var checklist = [
            agentRow("1", "kept", id: keptId),
            agentRow("2", "dropped"),
        ]
        let items = workspaceAgentChecklistReplacement(
            existing: checklist,
            agentTasks: [task("1", "kept", .completed, id: keptId)],
            workstreamId: mine
        )
        #expect(items?.map(\.text) == ["kept"])
        checklist.replaceChecklist(with: items ?? [])
        #expect(checklist.map(\.text) == ["kept"])
        #expect(checklist.first?.state == .completed)
    }

    /// Two agents in one workspace must not erase each other.
    @Test func rowsOwnedByAnotherAgentSurvive() {
        let otherId = UUID()
        let existing = [
            agentRow("1", "other agent task", .inProgress, workstreamId: theirs, id: otherId),
            agentRow("1", "old"),
        ]
        let fresh = task("2", "new")
        let items = workspaceAgentChecklistReplacement(
            existing: existing,
            agentTasks: [fresh],
            workstreamId: mine
        )
        #expect(items?.map(\.text) == ["other agent task", "new"])
        #expect(items?.map(\.id) == [otherId, fresh.id])
    }

    /// Ownership lives on the row, so it survives a restart that emptied every
    /// in-memory accumulator.
    @Test func ownershipIsRecoveredFromPersistedRows() {
        let rowId = UUID()
        let restored = [
            WorkspaceChecklistItem(text: "typed by hand", state: .pending, origin: .user),
            agentRow("7", "restored agent row", id: rowId),
        ]
        let items = workspaceAgentChecklistReplacement(
            existing: restored,
            agentTasks: [task("7", "restored agent row", .completed, id: rowId)],
            workstreamId: mine
        )
        #expect(items?.map(\.state) == [.pending, .completed])
        #expect(items?.map(\.id) == [restored[0].id, rowId])
    }

    /// An all-deleted report retires the agent's own rows and nothing else.
    @Test func emptyReportRetiresOnlyOwnedRows() {
        let userItem = WorkspaceChecklistItem(text: "typed by hand", state: .pending, origin: .user)
        let existing = [userItem, agentRow("1", "agent row")]
        let items = workspaceAgentChecklistReplacement(
            existing: existing,
            agentTasks: [],
            workstreamId: mine
        )
        #expect(items?.map(\.id) == [userItem.id])
    }

    @Test func emptyReportWithNothingOwnedIsANoOp() {
        let existing = [
            WorkspaceChecklistItem(text: "typed by hand", state: .pending, origin: .user)
        ]
        #expect(workspaceAgentChecklistReplacement(
            existing: existing,
            agentTasks: [],
            workstreamId: mine
        ) == nil)
    }

    @Test func unchangedReportProducesNoWrite() {
        let rowId = UUID()
        let existing = [agentRow("1", "same", .inProgress, id: rowId)]
        #expect(workspaceAgentChecklistReplacement(
            existing: existing,
            agentTasks: [task("1", "same", .inProgress, id: rowId)],
            workstreamId: mine
        ) == nil)
    }

    @Test func replacementIsAcceptedByTheChecklistMerge() {
        var checklist: [WorkspaceChecklistItem] = []
        let a = task("1", "  read the code  ", .inProgress)
        guard let items = workspaceAgentChecklistReplacement(
            existing: checklist,
            agentTasks: [a],
            workstreamId: mine
        ) else {
            Issue.record("expected a replacement")
            return
        }
        #expect(checklist.replaceChecklist(with: items).isSuccess)
        #expect(checklist.map(\.text) == ["read the code"])
        #expect(checklist.first?.origin == .agent)
        #expect(checklist.first?.id == a.id)
        #expect(checklist.first?.agentTaskRef == a.ref)
    }

    /// The cap must never cost the user their own rows: only the incoming
    /// agent portion is trimmed.
    @Test func capTrimsAgentRowsAndNeverUserRows() {
        let userItems = (0..<10).map {
            WorkspaceChecklistItem(text: "user \($0)", state: .pending, origin: .user)
        }
        let tasks = (0..<WorkspaceChecklistItem.maxChecklistItems).map {
            task("\($0)", "task \($0)")
        }
        var checklist = userItems
        let items = workspaceAgentChecklistReplacement(
            existing: userItems,
            agentTasks: tasks,
            workstreamId: mine
        )
        #expect(items?.count == WorkspaceChecklistItem.maxChecklistItems)
        #expect(items?.prefix(10).map(\.text) == userItems.map(\.text))
        #expect(checklist.replaceChecklist(with: items ?? []).isSuccess)
        for userItem in userItems {
            #expect(checklist.contains { $0.id == userItem.id })
        }
    }

    @Test func agentReportIsDroppedWhenUserRowsFillTheCap() {
        let userItems = (0..<WorkspaceChecklistItem.maxChecklistItems).map {
            WorkspaceChecklistItem(text: "user \($0)", state: .pending, origin: .user)
        }
        let items = workspaceAgentChecklistReplacement(
            existing: userItems,
            agentTasks: [task("1", "agent task")],
            workstreamId: mine
        )
        // Nothing changes: the user's rows are never sacrificed for the agent.
        #expect(items == nil)
    }

    /// The persisted reference is optional, so checklists written before this
    /// existed still decode and are treated as unowned.
    @Test func rowsWithoutARefAreNeverClaimed() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","text":"legacy","state":"pending","origin":"agent"}"#
        let item = try JSONDecoder().decode(
            WorkspaceChecklistItem.self,
            from: Data(legacy.utf8)
        )
        #expect(item.agentTaskRef == nil)
        let items = workspaceAgentChecklistReplacement(
            existing: [item],
            agentTasks: [task("1", "new")],
            workstreamId: mine
        )
        #expect(items?.map(\.text) == ["legacy", "new"])
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
