import Foundation
import Testing
@testable import CmuxWorkspaces

/// Coverage for folding an agent's reported task list into the workspace
/// checklist (https://github.com/manaflow-ai/cmux/issues/8960).
@Suite struct WorkspaceAgentChecklistSyncTests {
    private func task(
        _ id: UUID,
        _ text: String,
        _ state: WorkspaceChecklistItem.State = .pending
    ) -> WorkspaceAgentChecklistTask {
        WorkspaceAgentChecklistTask(id: id, text: text, state: state)
    }

    @Test func agentTasksAppendAfterRowsItDoesNotOwn() {
        let userItem = WorkspaceChecklistItem(text: "mine", state: .completed, origin: .user)
        let a = UUID(), b = UUID()
        let items = workspaceAgentChecklistReplacement(
            existing: [userItem],
            agentTasks: [task(a, "plan", .completed), task(b, "build", .inProgress)],
            ownedIds: [a, b]
        )
        #expect(items?.map(\.text) == ["mine", "plan", "build"])
        #expect(items?.map(\.id) == [userItem.id, a, b])
        #expect(items?.map(\.state) == [.completed, .completed, .inProgress])
        #expect(items?.map(\.origin) == [.user, .agent, .agent])
    }

    @Test func stalePreviouslyOwnedRowsAreRetired() {
        let a = UUID(), b = UUID()
        var checklist = [
            WorkspaceChecklistItem(id: a, text: "kept", state: .pending, origin: .agent),
            WorkspaceChecklistItem(id: b, text: "dropped", state: .pending, origin: .agent),
        ]
        let items = workspaceAgentChecklistReplacement(
            existing: checklist,
            agentTasks: [task(a, "kept", .completed)],
            ownedIds: [a, b]
        )
        #expect(items?.map(\.text) == ["kept"])
        checklist.replaceChecklist(with: items ?? [])
        #expect(checklist.map(\.text) == ["kept"])
        #expect(checklist.first?.state == .completed)
    }

    /// Two agents in one workspace must not erase each other. Regression for
    /// the first cut, which retained only `.user` rows.
    @Test func rowsOwnedByAnotherAgentSurvive() {
        let mine = UUID(), theirs = UUID()
        let existing = [
            WorkspaceChecklistItem(id: theirs, text: "other agent task", state: .inProgress, origin: .agent),
            WorkspaceChecklistItem(id: mine, text: "old", state: .pending, origin: .agent),
        ]
        let fresh = UUID()
        let items = workspaceAgentChecklistReplacement(
            existing: existing,
            agentTasks: [task(fresh, "new")],
            ownedIds: [mine, fresh]
        )
        #expect(items?.map(\.text) == ["other agent task", "new"])
        #expect(items?.map(\.id) == [theirs, fresh])
    }

    /// An all-deleted report retires the agent's own rows and nothing else.
    @Test func emptyReportRetiresOnlyOwnedRows() {
        let mine = UUID()
        let userItem = WorkspaceChecklistItem(text: "typed by hand", state: .pending, origin: .user)
        let existing = [
            userItem,
            WorkspaceChecklistItem(id: mine, text: "agent row", state: .pending, origin: .agent),
        ]
        let items = workspaceAgentChecklistReplacement(
            existing: existing,
            agentTasks: [],
            ownedIds: [mine]
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
            ownedIds: []
        ) == nil)
    }

    @Test func unchangedReportProducesNoWrite() {
        let a = UUID()
        let existing = [
            WorkspaceChecklistItem(id: a, text: "same", state: .inProgress, origin: .agent)
        ]
        #expect(workspaceAgentChecklistReplacement(
            existing: existing,
            agentTasks: [task(a, "same", .inProgress)],
            ownedIds: [a]
        ) == nil)
    }

    @Test func replacementIsAcceptedByTheChecklistMerge() {
        var checklist: [WorkspaceChecklistItem] = []
        let a = UUID()
        guard let items = workspaceAgentChecklistReplacement(
            existing: checklist,
            agentTasks: [task(a, "  read the code  ", .inProgress)],
            ownedIds: [a]
        ) else {
            Issue.record("expected a replacement")
            return
        }
        #expect(checklist.replaceChecklist(with: items).isSuccess)
        #expect(checklist.map(\.text) == ["read the code"])
        #expect(checklist.first?.origin == .agent)
        #expect(checklist.first?.id == a)
    }

    /// The cap must never cost the user their own rows: only the incoming
    /// agent portion is trimmed.
    @Test func capTrimsAgentRowsAndNeverUserRows() {
        let userItems = (0..<10).map {
            WorkspaceChecklistItem(text: "user \($0)", state: .pending, origin: .user)
        }
        let tasks = (0..<WorkspaceChecklistItem.maxChecklistItems).map {
            task(UUID(), "task \($0)")
        }
        var checklist = userItems
        let items = workspaceAgentChecklistReplacement(
            existing: userItems,
            agentTasks: tasks,
            ownedIds: Set(tasks.map(\.id))
        )
        #expect(items?.count == WorkspaceChecklistItem.maxChecklistItems)
        #expect(items?.prefix(10).map(\.text) == userItems.map(\.text))
        #expect(checklist.replaceChecklist(with: items ?? []).isSuccess)
        // Every user row survived; the agent list was truncated instead.
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
            agentTasks: [task(UUID(), "agent task")],
            ownedIds: [UUID()]
        )
        // Nothing changes: the user's rows are never sacrificed for the agent.
        #expect(items == nil)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
