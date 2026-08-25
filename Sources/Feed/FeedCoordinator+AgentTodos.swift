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
        guard isTaskEvent,
              let store,
              store.ownedTaskIds(forWorkstream: event.sessionId).isEmpty else {
            return
        }
        // An accumulator can be empty after restart while persisted rows still
        // carry exact workstream/task ownership. Seed from every live workspace
        // before applying a status-only delta.
        let candidates = AppDelegate.shared?.allWorkspacesForAgentTodoRetirement ?? []
        guard !candidates.isEmpty, markTodoRecoveryAttempt(event.sessionId) else { return }
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
            tasks: todos,
            workstreamId: item.workstreamId
        )
        retireAgentTodos(for: item.workstreamId, excluding: workspace.id)
        let existingAgentItems = workspace.todoState.checklist.reduce(into: [WorkspaceAgentTaskRef: WorkspaceChecklistItem]()) { result, checklistItem in
            if let ref = checklistItem.agentTaskRef {
                result[ref] = checklistItem
            }
        }
        let tasks = todos.map { todo in
            let state = checklistState(for: todo.state)
            let ref = WorkspaceAgentTaskRef(workstreamId: item.workstreamId, taskId: todo.id)
            let previous = existingAgentItems[ref]
            let normalizedText = WorkspaceChecklistItem.normalizedText(todo.content) ?? todo.content
            let activity = previous?.text == normalizedText && previous?.state == state
                ? previous?.lastActivityAt ?? event.receivedAt
                : event.receivedAt
            WorkspaceAgentChecklistTask(
                id: todo.stableChecklistItemId(workstreamId: item.workstreamId),
                ref: ref,
                text: todo.content,
                state: state,
                lastActivityAt: activity,
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
        defer { recordTodoWorkspace(workstreamId: workstreamId, workspaceID: workspaceID) }
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

    /// A dispatched workspace is dedicated to one source checklist row. Once
    /// every task reported by that workspace is complete, the indexed source
    /// row is completed through `Workspace+Todos`. Recovery scans persisted
    /// bindings at most once per target workspace after a restart.
    @MainActor
    private func reconcileDispatchedItems(
        in agentWorkspace: Workspace,
        tasks: [WorkstreamTaskTodo],
        workstreamId: String
    ) {
        guard let app = AppDelegate.shared,
              FeedCoordinator.shared.store?.isTaskListComplete(forWorkstream: workstreamId) ?? false else {
            return
        }
        guard !tasks.isEmpty, tasks.allSatisfy({ $0.state == .completed }) else { return }
        if dispatchedTaskOwners(for: agentWorkspace.id).isEmpty,
           markDispatchTargetRecoveryScan(agentWorkspace.id) {
            for workspace in app.allWorkspacesForAgentTodoRetirement {
                for item in workspace.todoState.checklist where item.boundWorkspaceID == agentWorkspace.id {
                    registerDispatchedTask(
                        itemID: item.id,
                        sourceWorkspaceID: workspace.id,
                        targetWorkspaceID: agentWorkspace.id
                    )
                }
            }
        }
        let owners = dispatchedTaskOwners(for: agentWorkspace.id)
        guard owners.count == 1, let owner = owners.first,
              let sourceManager = app.tabManagerFor(tabId: owner.sourceWorkspaceID),
              let sourceWorkspace = sourceManager.tabs.first(where: { $0.id == owner.sourceWorkspaceID }) else {
            return
        }
        _ = sourceWorkspace.setChecklistItemState(id: owner.itemID, state: .completed)
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
