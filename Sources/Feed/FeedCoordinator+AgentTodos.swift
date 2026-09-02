import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation

/// Bridges agent task-tool payloads into the owning workspace checklist.
/// `WorkspaceTodoState` remains the sole mutable task store; Feed only maps
/// wire values and invokes the shared `Workspace.replaceChecklist` entry point.
extension FeedCoordinator {
    @MainActor
    func recoverAgentTodosIfNeeded(for event: WorkstreamEvent, workstreamID: String) {
        let isTaskEvent = event.hookEventName == .todoWrite
            || event.toolName.flatMap(WorkstreamTaskTool.init(rawValue:)) != nil
        guard isTaskEvent,
              let store,
              store.ownedTaskIds(forWorkstream: workstreamID).isEmpty else {
            return
        }
        // An accumulator can be empty after restart while persisted rows still
        // carry exact workstream/task ownership. Seed from every live workspace
        // before applying a status-only delta.
        let candidates = AppDelegate.shared?.allWorkspacesForAgentTodoRetirement ?? []
        guard !candidates.isEmpty else { return }
        ensureAgentTodoOwnershipIndex(from: candidates)
        guard markTodoRecoveryAttempt(
            workstreamID,
            recoveryEpoch: store.taskToolRecoveryEpoch
        ) else { return }
        var restored: [WorkstreamTaskTodo] = []
        var seen = Set<String>()
        for workspace in candidates {
            for item in workspace.todoState.checklist {
                guard let ref = item.agentTaskRef,
                      store.normalizedWorkstreamID(
                          rawValue: ref.workstreamId,
                          source: event.source
                      ) == workstreamID,
                      seen.insert(ref.taskId).inserted else { continue }
                restored.append(WorkstreamTaskTodo(
                    id: ref.taskId,
                    content: item.text,
                    state: taskState(for: item.state)
                ))
            }
        }
        if !restored.isEmpty {
            store.seedTaskTodos(forWorkstream: workstreamID, todos: restored)
        }
    }

    @MainActor
    func applyAgentTodos(from item: WorkstreamItem, event: WorkstreamEvent) {
        guard case .todos(let todos) = item.payload,
              let workspace = resolveTodoWorkspace(for: event) else { return }
        ensureAgentTodoOwnershipIndex()
        reconcileDispatchedItems(
            in: workspace,
            tasks: todos,
            workstreamId: item.workstreamId
        )
        retireAgentTodos(
            for: item.workstreamId,
            rawWorkstreamId: event.sessionId,
            excluding: workspace.id,
            source: event.source
        )
        guard let store else { return }
        var matchingWorkstreamIDs = Set([item.workstreamId])
        let existingAgentItems = workspace.todoState.checklist.reduce(into: [WorkspaceAgentTaskRef: WorkspaceChecklistItem]()) { result, checklistItem in
            if let ref = checklistItem.agentTaskRef {
                let canonicalWorkstreamID = store.normalizedWorkstreamID(
                    rawValue: ref.workstreamId,
                    source: event.source
                )
                if canonicalWorkstreamID == item.workstreamId {
                    matchingWorkstreamIDs.insert(ref.workstreamId)
                }
                let canonicalRef = WorkspaceAgentTaskRef(
                    workstreamId: canonicalWorkstreamID,
                    taskId: ref.taskId
                )
                result[canonicalRef] = checklistItem
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
            return WorkspaceAgentChecklistTask(
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
            workstreamId: item.workstreamId,
            matchingWorkstreamIds: matchingWorkstreamIDs
        ) else { return }
        _ = workspace.replaceChecklist(with: replacements)
        refreshAgentTodoOwnershipIndex(for: workspace)
        WorkspaceTodoFeature.markUsed()
    }

    @MainActor
    private func retireAgentTodos(
        for workstreamId: String,
        rawWorkstreamId: String,
        excluding workspaceID: UUID,
        source: String
    ) {
        // Persisted checklist ownership remains authoritative. The index only
        // narrows the candidate workspaces; each candidate is still inspected
        // before mutation, so stale entries cannot delete unrelated rows.
        guard let store, let app = AppDelegate.shared else { return }
        let candidateIDs = agentTodoWorkspaceIDs(
            forRawWorkstreamIDs: [rawWorkstreamId, workstreamId],
            canonicalWorkstreamID: workstreamId,
            source: source
        )
        let workspacesByID = Dictionary(
            app.allWorkspacesForAgentTodoRetirement.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for candidateID in candidateIDs where candidateID != workspaceID {
            guard let workspace = workspacesByID[candidateID] else { continue }
            var matchingWorkstreamIDs = Set<String>()
            for checklistItem in workspace.todoState.checklist {
                guard let rawWorkstreamID = checklistItem.agentTaskRef?.workstreamId,
                      store.normalizedWorkstreamID(
                          rawValue: rawWorkstreamID,
                          source: source
                      ) == workstreamId else { continue }
                matchingWorkstreamIDs.insert(rawWorkstreamID)
            }
            guard !matchingWorkstreamIDs.isEmpty else { continue }
            guard let replacements = WorkspaceAgentChecklistSync().replacement(
                existing: workspace.todoState.checklist,
                agentTasks: [],
                workstreamId: workstreamId,
                matchingWorkstreamIds: matchingWorkstreamIDs
            ) else { continue }
            _ = workspace.replaceChecklist(with: replacements)
            refreshAgentTodoOwnershipIndex(for: workspace)
        }
    }

    /// Rebuilds the ownership index once the app has a stable restored
    /// workspace projection. A caller may provide the already-read workspace
    /// list to avoid a second route enumeration during recovery.
    @MainActor
    private func ensureAgentTodoOwnershipIndex(
        from suppliedWorkspaces: [Workspace]? = nil
    ) {
        guard !hasBuiltAgentTodoOwnershipIndex else { return }
        let workspaces = suppliedWorkspaces
            ?? AppDelegate.shared?.allWorkspacesForAgentTodoRetirement
            ?? []
        guard !workspaces.isEmpty || AppDelegate.shared?.didAttemptStartupSessionRestore == true else {
            return
        }
        agentTodoWorkspaceIDsByRawWorkstream.removeAll(keepingCapacity: true)
        agentTodoRawWorkstreamsByWorkspace.removeAll(keepingCapacity: true)
        for workspace in workspaces {
            refreshAgentTodoOwnershipIndex(for: workspace)
        }
        hasBuiltAgentTodoOwnershipIndex = true
    }

    /// Replaces one workspace's raw-identity entries in the ownership index.
    @MainActor
    private func refreshAgentTodoOwnershipIndex(for workspace: Workspace) {
        let oldRawIDs = agentTodoRawWorkstreamsByWorkspace[workspace.id] ?? []
        for rawID in oldRawIDs {
            agentTodoWorkspaceIDsByRawWorkstream[rawID]?.remove(workspace.id)
            if agentTodoWorkspaceIDsByRawWorkstream[rawID]?.isEmpty == true {
                agentTodoWorkspaceIDsByRawWorkstream.removeValue(forKey: rawID)
            }
        }
        let rawIDs = Set(workspace.todoState.checklist.compactMap { $0.agentTaskRef?.workstreamId })
        agentTodoRawWorkstreamsByWorkspace[workspace.id] = rawIDs
        for rawID in rawIDs {
            agentTodoWorkspaceIDsByRawWorkstream[rawID, default: []].insert(workspace.id)
        }
    }

    /// Returns candidate owners for raw and canonical identities.
    @MainActor
    private func agentTodoWorkspaceIDs(
        forRawWorkstreamIDs rawIDs: [String],
        canonicalWorkstreamID: String,
        source: String
    ) -> Set<UUID> {
        ensureAgentTodoOwnershipIndex()
        guard let store else { return [] }
        let exactIDs = Set(rawIDs)
        return agentTodoWorkspaceIDsByRawWorkstream.reduce(into: Set<UUID>()) { result, entry in
            let matches = exactIDs.contains(entry.key)
                || store.normalizedWorkstreamID(
                    rawValue: entry.key,
                    source: source
                ) == canonicalWorkstreamID
            if matches {
                result.formUnion(entry.value)
            }
        }
    }

    /// Invalidates the lazy index when a restored session replaces checklist
    /// state before the next task event arrives.
    @MainActor
    func invalidateAgentTodoOwnershipIndex() {
        hasBuiltAgentTodoOwnershipIndex = false
        agentTodoWorkspaceIDsByRawWorkstream.removeAll(keepingCapacity: true)
        agentTodoRawWorkstreamsByWorkspace.removeAll(keepingCapacity: true)
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
        guard sourceWorkspace.todoState.checklist.contains(where: { $0.id == owner.itemID }) else { return }
        _ = sourceWorkspace.setChecklistItemState(id: owner.itemID, state: .completed)
        _ = sourceWorkspace.clearChecklistItemBinding(id: owner.itemID)
        clearDispatchedTaskOwners(for: agentWorkspace.id)
    }

    @MainActor
    func releaseDispatchedBindings(forTargetWorkspaceID targetWorkspaceID: UUID) {
        let owners = dispatchedTaskOwners(for: targetWorkspaceID)
        if !owners.isEmpty, let app = AppDelegate.shared {
            var resolvedOwnerCount = 0
            for owner in owners {
                guard let manager = app.tabManagerFor(tabId: owner.sourceWorkspaceID),
                      let sourceWorkspace = manager.tabs.first(where: { $0.id == owner.sourceWorkspaceID }) else {
                    continue
                }
                _ = sourceWorkspace.clearChecklistItemBinding(id: owner.itemID)
                resolvedOwnerCount += 1
            }
            if resolvedOwnerCount == owners.count {
                clearDispatchedTaskOwners(for: targetWorkspaceID)
                return
            }
        }
        guard let app = AppDelegate.shared else { return }
        for workspace in app.allWorkspacesForAgentTodoRetirement {
            for item in workspace.todoState.checklist where item.boundWorkspaceID == targetWorkspaceID {
                _ = workspace.clearChecklistItemBinding(id: item.id)
            }
        }
        clearDispatchedTaskOwners(for: targetWorkspaceID)
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
