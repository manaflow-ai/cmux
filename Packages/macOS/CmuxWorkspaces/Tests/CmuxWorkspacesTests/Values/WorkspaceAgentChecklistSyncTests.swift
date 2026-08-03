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

    @Test func emptyReportIsANoOpSoUserItemsSurvive() {
        let existing = [
            WorkspaceChecklistItem(text: "typed by hand", state: .pending, origin: .user)
        ]
        #expect(WorkspaceAgentChecklistSync.replacementItems(
            existing: existing,
            agentTasks: []
        ) == nil)
    }

    @Test func agentTasksAppendAfterUserItems() {
        let userItem = WorkspaceChecklistItem(text: "mine", state: .completed, origin: .user)
        let a = UUID(), b = UUID()
        let items = WorkspaceAgentChecklistSync.replacementItems(
            existing: [userItem],
            agentTasks: [task(a, "plan", .completed), task(b, "build", .inProgress)]
        )
        #expect(items?.map(\.text) == ["mine", "plan", "build"])
        #expect(items?.map(\.id) == [userItem.id, a, b])
        #expect(items?.map(\.state) == [.completed, .completed, .inProgress])
        #expect(items?.map(\.origin) == [.user, .agent, .agent])
    }

    @Test func staleAgentRowsAreDropped() {
        let a = UUID(), b = UUID()
        var checklist = [
            WorkspaceChecklistItem(id: a, text: "kept", state: .pending, origin: .agent),
            WorkspaceChecklistItem(id: b, text: "dropped", state: .pending, origin: .agent),
        ]
        let items = WorkspaceAgentChecklistSync.replacementItems(
            existing: checklist,
            agentTasks: [task(a, "kept", .completed)]
        )
        #expect(items?.map(\.text) == ["kept"])
        checklist.replaceChecklist(with: items ?? [])
        #expect(checklist.map(\.text) == ["kept"])
        #expect(checklist.first?.state == .completed)
    }

    @Test func unchangedReportProducesNoWrite() {
        let a = UUID()
        let existing = [
            WorkspaceChecklistItem(id: a, text: "same", state: .inProgress, origin: .agent)
        ]
        #expect(WorkspaceAgentChecklistSync.replacementItems(
            existing: existing,
            agentTasks: [task(a, "same", .inProgress)]
        ) == nil)
    }

    @Test func replacementIsAcceptedByTheChecklistMerge() {
        var checklist: [WorkspaceChecklistItem] = []
        let a = UUID()
        guard let items = WorkspaceAgentChecklistSync.replacementItems(
            existing: checklist,
            agentTasks: [task(a, "  read the code  ", .inProgress)]
        ) else {
            Issue.record("expected a replacement")
            return
        }
        #expect(checklist.replaceChecklist(with: items).isSuccess)
        #expect(checklist.map(\.text) == ["read the code"])
        #expect(checklist.first?.origin == .agent)
        #expect(checklist.first?.id == a)
    }

    @Test func overlongReportsStayWithinTheChecklistCap() {
        let tasks = (0..<(WorkspaceChecklistItem.maxChecklistItems + 5)).map {
            task(UUID(), "task \($0)")
        }
        var checklist: [WorkspaceChecklistItem] = []
        let items = WorkspaceAgentChecklistSync.replacementItems(
            existing: checklist,
            agentTasks: tasks
        )
        #expect(items?.count == WorkspaceChecklistItem.maxChecklistItems)
        #expect(checklist.replaceChecklist(with: items ?? []).isSuccess)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
