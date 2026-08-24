import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation

/// Bridges agent task-tool payloads into the owning workspace checklist.
/// `WorkspaceTodoState` remains the sole mutable task store; Feed only maps
/// wire values and invokes the shared `Workspace.replaceChecklist` entry point.
extension FeedCoordinator {
    @MainActor
    func recoverAgentTodosIfNeeded(for event: WorkstreamEvent) {
        let isTaskEvent = event.hookEventName == .todoWrite
            || event.toolName.flatMap(WorkstreamTaskTool.init(rawValue:)) != nil
        guard isTaskEvent, let store, store.ownedTaskIds(forWorkstream: event.sessionId).isEmpty else {
            return
        }
        // An accumulator can be empty after restart while persisted rows still
        // carry exact workstream/task ownership. Seed from every live workspace
        // before applying a status-only delta.
        let candidates = AppDelegate.shared?.allWorkspacesForAgentTodoRetirement ?? []
        var restored: [WorkstreamTaskTodo] = []
        var seen = Set<String>()
        for workspace in candidates {
            for item in workspace.todoState.checklist {
                guard let ref = item.agentTaskRef,
                      ref.workstreamId == event.sessionId,
                      seen.insert(ref.taskId).inserted else { continue }
                restored.append(WorkstreamTaskTodo(
                    id: ref.taskId,
                    content: item.text,
                    state: taskState(for: item.state)
                ))
            }
        }
        if !restored.isEmpty {
            store.seedTaskTodos(forWorkstream: event.sessionId, todos: restored)
        }
    }

    @MainActor
    func applyAgentTodos(from item: WorkstreamItem, event: WorkstreamEvent) {
        guard case .todos(let todos) = item.payload,
              let workspace = resolveTodoWorkspace(for: event) else { return }
        reconcileDispatchedItems(
            in: workspace,
            tasks: todos
        )
        retireAgentTodos(for: item.workstreamId, excluding: workspace.id)
        let tasks = todos.map { todo in
            WorkspaceAgentChecklistTask(
                id: todo.stableChecklistItemId(workstreamId: item.workstreamId),
                ref: WorkspaceAgentTaskRef(workstreamId: item.workstreamId, taskId: todo.id),
                text: todo.content,
                state: checklistState(for: todo.state),
                lastActivityAt: event.receivedAt,
                agentName: event.source
            )
        }
        guard let replacements = WorkspaceAgentChecklistSync().replacement(
            existing: workspace.todoState.checklist,
            agentTasks: tasks,
            workstreamId: item.workstreamId
        ) else { return }
        _ = workspace.replaceChecklist(with: replacements)
        WorkspaceTodoFeature.markUsed()
    }

    @MainActor
    private func retireAgentTodos(for workstreamId: String, excluding workspaceID: UUID) {
        if lastTodoWorkspaceByWorkstream[workstreamId] == workspaceID { return }
        defer { lastTodoWorkspaceByWorkstream[workstreamId] = workspaceID }
        for workspace in AppDelegate.shared?.allWorkspacesForAgentTodoRetirement ?? [] where workspace.id != workspaceID {
            guard workspace.todoState.checklist.contains(where: {
                $0.agentTaskRef?.workstreamId == workstreamId
            }) else { continue }
            guard let replacements = WorkspaceAgentChecklistSync().replacement(
                existing: workspace.todoState.checklist,
                agentTasks: [],
                workstreamId: workstreamId
            ) else { continue }
            _ = workspace.replaceChecklist(with: replacements)
        }
    }

    /// A dispatched user row has no agent task id until its new workspace
    /// emits hooks. Match the durable target workspace and normalized text so
    /// completion can flow back through the same checklist state mutation
    /// path without introducing a second task store.
    @MainActor
    private func reconcileDispatchedItems(
        in agentWorkspace: Workspace,
        tasks: [WorkstreamTaskTodo]
    ) {
        guard let app = AppDelegate.shared else { return }
        let completedText = Set(tasks.filter { $0.state == .completed }.map {
            WorkspaceChecklistItem.normalizedText($0.content) ?? $0.content
        })
        guard !completedText.isEmpty else { return }
        for workspace in app.allWorkspacesForAgentTodoRetirement {
            for checklistItem in workspace.todoState.checklist where
                checklistItem.boundWorkspaceID == agentWorkspace.id &&
                completedText.contains(WorkspaceChecklistItem.normalizedText(checklistItem.text) ?? checklistItem.text) {
                _ = workspace.setChecklistItemState(id: checklistItem.id, state: .completed)
            }
        }
    }

    @MainActor
    private func resolveTodoWorkspace(for event: WorkstreamEvent) -> Workspace? {
        guard let raw = event.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let workspaceID = UUID(uuidString: raw),
              let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) else { return nil }
        return manager.tabs.first { $0.id == workspaceID }
    }

    private func checklistState(for state: WorkstreamTaskTodo.State) -> WorkspaceChecklistItem.State {
        switch state {
        case .pending: .pending
        case .inProgress: .inProgress
        case .completed: .completed
        }
    }

    private func taskState(for state: WorkspaceChecklistItem.State) -> WorkstreamTaskTodo.State {
        switch state {
        case .pending: .pending
        case .inProgress: .inProgress
        case .completed: .completed
        }
    }
}
