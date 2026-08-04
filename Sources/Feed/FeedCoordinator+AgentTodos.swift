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
    /// Restores a workstream's task list from its persisted checklist rows
    /// before a delta is applied.
    ///
    /// The store's accumulator is process-local, so an app restart, a dropped
    /// event, or LRU eviction leaves it empty while the rows are still on
    /// disk. Without this, the ordinary status-only `TaskUpdate` that follows
    /// names an id the store has never seen and is dropped, stranding the
    /// checklist. The rows carry their own `agentTaskRef`, so recovery is
    /// exact rather than a guess.
    @MainActor
    func recoverAgentTodosIfNeeded(for event: WorkstreamEvent) {
        // `.todoWrite` producers (the OpenCode plugin) send no tool name, so
        // the hook event name is the only signal that this is a task event.
        let isTaskEvent = event.hookEventName == .todoWrite
            || (event.toolName.map(isWorkstreamTaskTool) ?? false)
        guard isTaskEvent else { return }
        guard let store, !store.hasTaskTodos(forWorkstream: event.sessionId) else { return }
        guard let workspace = Self.resolveTodoWorkspace(for: event) else { return }

        let restored = workspace.todoState.checklist.compactMap { item -> WorkstreamTaskTodo? in
            guard let ref = item.agentTaskRef, ref.workstreamId == event.sessionId else { return nil }
            return WorkstreamTaskTodo(
                id: ref.taskId,
                content: item.text,
                state: Self.todoState(for: item.state)
            )
        }
        store.seedTaskTodos(forWorkstream: event.sessionId, todos: restored)
    }

    @MainActor
    func applyAgentTodos(from item: WorkstreamItem, event: WorkstreamEvent) {
        guard case .todos(let todos) = item.payload else { return }
        guard let workspace = Self.resolveTodoWorkspace(for: event) else { return }

        let workstreamId = item.workstreamId
        // A surface can move between workspaces mid-session. The agent's rows
        // are recreated in the new one below, so retire the copies it left
        // behind or they linger there forever, skewing that workspace's
        // progress with tasks no later delta will ever touch.
        Self.retireAgentTodos(forWorkstream: workstreamId, excluding: workspace.id)
        let tasks = todos.map { todo in
            WorkspaceAgentChecklistTask(
                id: todo.stableChecklistItemId(workstreamId: workstreamId),
                ref: WorkspaceAgentTaskRef(workstreamId: workstreamId, taskId: todo.id),
                text: todo.content,
                state: Self.checklistState(for: todo.state)
            )
        }
        guard let replacements = workspaceAgentChecklistReplacement(
            existing: workspace.todoState.checklist,
            agentTasks: tasks,
            workstreamId: workstreamId
        ) else { return }
        workspace.replaceChecklist(with: replacements)
        WorkspaceTodoFeature.markUsed()
    }

    /// Clears this workstream's rows from every workspace other than the one
    /// it now writes to.
    ///
    /// Driven by the persisted `agentTaskRef` on each row rather than by
    /// in-process bookkeeping, so it still finds rows a previous app run left
    /// behind — a surface that moves while cmux is restarting would otherwise
    /// strand a full copy of the plan in its old workspace.
    @MainActor
    private static func retireAgentTodos(forWorkstream workstreamId: String, excluding current: UUID) {
        guard let appDelegate = AppDelegate.shared else { return }
        for workspace in appDelegate.allWorkspacesForAgentTodoRetirement where workspace.id != current {
            guard workspace.todoState.checklist.contains(where: {
                $0.agentTaskRef?.workstreamId == workstreamId
            }) else { continue }
            guard let replacements = workspaceAgentChecklistReplacement(
                existing: workspace.todoState.checklist,
                agentTasks: [],
                workstreamId: workstreamId
            ) else { continue }
            workspace.replaceChecklist(with: replacements)
        }
    }

    /// Resolves the workspace whose checklist this event may mutate.
    ///
    /// Only the event's own `workspace_id` is trusted, and the write fails
    /// closed without it. For task tools the feed hook re-homes that value
    /// against the surface's current owner before sending, so a moved pane
    /// routes to the workspace it lives in now rather than the one its
    /// terminal inherited at spawn.
    ///
    /// Deliberately not `resolveAttentionTarget`: it prefers the same
    /// `event.workspaceId` and merely adds an on-disk hook-session fallback,
    /// so it re-homes nothing here while letting a stale record write rows
    /// into a workspace the session has left, and it would put a synchronous
    /// file read and JSON parse on the main actor for every task event.
    @MainActor
    private static func resolveTodoWorkspace(for event: WorkstreamEvent) -> Workspace? {
        guard let raw = event.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let workspaceId = UUID(uuidString: raw),
              let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
        else { return nil }
        return tabManager.tabs.first { $0.id == workspaceId }
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

    private static func todoState(
        for state: WorkspaceChecklistItem.State
    ) -> WorkstreamTaskTodo.State {
        switch state {
        case .pending: return .pending
        case .inProgress: return .inProgress
        case .completed: return .completed
        }
    }
}
