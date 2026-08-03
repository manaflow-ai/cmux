import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation

/// Bridges an agent's reported task list into its workspace's todo checklist,
/// so the sidebar summary, the todo pane, and `cmux todo list` all reflect the
/// plan the agent is working through.
///
/// The Feed store already materializes `.todos` payloads from every producer
/// (Claude's `TaskCreate` / `TaskUpdate`, the whole-list `TodoWrite` shape, the
/// OpenCode plugin). Before this, nothing carried them out of the Feed panel,
/// so the checklist only ever filled from an explicit `cmux todo set`.
/// See https://github.com/manaflow-ai/cmux/issues/8960.
extension FeedCoordinator {
    @MainActor
    func applyAgentTodos(from item: WorkstreamItem, event: WorkstreamEvent) {
        guard case .todos(let todos) = item.payload else { return }
        guard let store else { return }
        guard let workspace = Self.resolveTodoWorkspace(for: event) else { return }

        let workstreamId = item.workstreamId
        let ownedIds = Set(
            store.ownedTaskIds(forWorkstream: workstreamId).map {
                workstreamChecklistItemId(workstreamId: workstreamId, taskId: $0)
            }
        )
        // Nothing owned and nothing reported means this producer has never
        // contributed a row; applying it could only churn.
        guard !ownedIds.isEmpty || !todos.isEmpty else { return }

        let tasks = todos.map { todo in
            WorkspaceAgentChecklistTask(
                id: todo.stableChecklistItemId(workstreamId: workstreamId),
                text: todo.content,
                state: Self.checklistState(for: todo.state)
            )
        }
        // Whole-list producers (TodoWrite, the OpenCode plugin) keep no
        // accumulator, so fall back to owning exactly what they just reported.
        let owned = ownedIds.isEmpty ? Set(tasks.map(\.id)) : ownedIds
        guard let replacements = workspaceAgentChecklistReplacement(
            existing: workspace.todoState.checklist,
            agentTasks: tasks,
            ownedIds: owned
        ) else { return }
        workspace.replaceChecklist(with: replacements)
        WorkspaceTodoFeature.markUsed()
    }

    @MainActor
    private static func resolveTodoWorkspace(for event: WorkstreamEvent) -> Workspace? {
        guard let target = resolveAttentionTarget(event: event),
              let tabManager = AppDelegate.shared?.tabManagerFor(tabId: target.workspaceId)
        else { return nil }
        return tabManager.tabs.first { $0.id == target.workspaceId }
    }

    private static func checklistState(
        for state: WorkstreamTaskTodo.State
    ) -> WorkspaceChecklistItem.State {
        switch state {
        case .pending: return .pending
        case .inProgress: return .inProgress
        case .completed: return .completed
        }
    }
}
