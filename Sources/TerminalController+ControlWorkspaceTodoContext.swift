import CmuxControlSocket
import CmuxWorkspaces
import Foundation

/// The workspace-todo witnesses for ``ControlCommandCoordinator``: resolves
/// the target workspace — the explicit id workspace-owner-first (like
/// `workspace.prompt_submit`), else the routed window's selected workspace —
/// and reads/mutates its todo state exclusively through the shared
/// `Workspace+Todos` entry points, so socket callers get the same caps,
/// normalization, and override anti-rot as the CLI and the sidebar UI.
extension TerminalController: ControlWorkspaceTodoContext {
    // MARK: - Workspace resolution

    private enum TodoWorkspaceResolution {
        case tabManagerUnavailable
        case notFound
        case found(tabManager: TabManager, workspace: Workspace)
    }

    private func resolveTodoWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> TodoWorkspaceResolution {
        if let workspaceID {
            if let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
               let workspace = owner.tabs.first(where: { $0.id == workspaceID }) {
                return .found(tabManager: owner, workspace: workspace)
            }
            guard let tabManager = resolveTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                return .notFound
            }
            return .found(tabManager: tabManager, workspace: workspace)
        }
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let selectedId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            return .notFound
        }
        return .found(tabManager: tabManager, workspace: workspace)
    }

    // MARK: - Snapshots

    private func todoStatusSnapshot(for workspace: Workspace) -> ControlWorkspaceTodoStatusSnapshot {
        let signals = workspace.taskStatusSignals()
        let inferred = WorkspaceTaskStatus.inferred(from: signals)
        let override = workspace.todoState.statusOverride
        let effective = WorkspaceTaskStatusOverride.effectiveStatus(
            override: override,
            inferred: inferred
        ).effective
        return ControlWorkspaceTodoStatusSnapshot(
            workspaceID: workspace.id,
            effective: effective.rawValue,
            inferred: inferred.rawValue,
            overrideStatus: override?.status.rawValue,
            overrideInferredAt: override?.inferredAtOverride.rawValue,
            signals: ControlWorkspaceTodoStatusSnapshot.Signals(
                anyAgentNeedsInput: signals.anyAgentNeedsInput,
                anyAgentRunning: signals.anyAgentRunning,
                anyOpenPullRequest: signals.anyOpenPullRequest,
                hasPullRequests: signals.hasPullRequests,
                allPullRequestsMergedOrClosed: signals.allPullRequestsMergedOrClosed,
                isGitDirty: signals.isGitDirty
            )
        )
    }

    private func todoChecklistSnapshot(for workspace: Workspace) -> ControlWorkspaceTodoChecklistSnapshot {
        let progress = workspace.checklistProgressSummary
        return ControlWorkspaceTodoChecklistSnapshot(
            workspaceID: workspace.id,
            items: workspace.todoState.checklist.map { item in
                ControlWorkspaceTodoChecklistSnapshot.Item(
                    id: item.id,
                    text: item.text,
                    state: item.state.rawValue,
                    origin: item.origin.rawValue
                )
            },
            completedCount: progress.completedCount,
            firstUncheckedText: progress.firstUncheckedText
        )
    }

    private func todoItemSnapshot(_ item: WorkspaceChecklistItem) -> ControlWorkspaceTodoChecklistSnapshot.Item {
        ControlWorkspaceTodoChecklistSnapshot.Item(
            id: item.id,
            text: item.text,
            state: item.state.rawValue,
            origin: item.origin.rawValue
        )
    }

    /// Resolves the id-or-index item selector against the live checklist.
    private func todoItem(
        in workspace: Workspace,
        itemID: UUID?,
        itemIndex: Int?
    ) -> WorkspaceChecklistItem? {
        if let itemID {
            return workspace.todoState.checklist.first(where: { $0.id == itemID })
        }
        if let itemIndex {
            return workspace.checklistItem(atIndex: itemIndex)
        }
        return nil
    }

    // MARK: - Status

    func controlWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoStatusResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            workspace.reconcileExpiredTaskStatusOverride()
            return .resolved(
                windowID: AppDelegate.shared?.windowId(for: tabManager),
                status: todoStatusSnapshot(for: workspace)
            )
        }
    }

    func controlSetWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        statusRaw: String?
    ) -> ControlWorkspaceTodoStatusResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            if let statusRaw {
                if statusRaw == "none" {
                    workspace.hideTaskStatus()
                } else {
                    guard let status = WorkspaceTaskStatus(rawValue: statusRaw) else {
                        return .invalidStatus(statusRaw)
                    }
                    workspace.setTaskStatusOverride(status)
                }
            } else {
                workspace.clearTaskStatusOverride()
            }
            // Progressive disclosure: the first successful mutation from any
            // entrypoint turns the sidebar todo UI on.
            WorkspaceTodoFeature.markUsed()
            return .resolved(
                windowID: AppDelegate.shared?.windowId(for: tabManager),
                status: todoStatusSnapshot(for: workspace)
            )
        }
    }

    func controlCycleWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoStatusResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            workspace.cycleTaskStatus()
            WorkspaceTodoFeature.markUsed()
            return .resolved(
                windowID: AppDelegate.shared?.windowId(for: tabManager),
                status: todoStatusSnapshot(for: workspace)
            )
        }
    }

    // MARK: - Checklist

    func controlWorkspaceTodoList(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoChecklistResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            return .resolved(
                windowID: AppDelegate.shared?.windowId(for: tabManager),
                checklist: todoChecklistSnapshot(for: workspace)
            )
        }
    }

    func controlWorkspaceTodoAdd(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        text: String,
        stateRaw: String?,
        originRaw: String?
    ) -> ControlWorkspaceTodoMutationResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            var state = WorkspaceChecklistItem.State.pending
            if let stateRaw {
                guard let parsed = WorkspaceChecklistItem.State(rawValue: stateRaw) else {
                    return .invalidState(stateRaw)
                }
                state = parsed
            }
            var origin = WorkspaceChecklistItem.Origin.user
            if let originRaw {
                guard let parsed = WorkspaceChecklistItem.Origin(rawValue: originRaw) else {
                    return .invalidOrigin(originRaw)
                }
                origin = parsed
            }
            switch workspace.addChecklistItem(text: text, state: state, origin: origin) {
            case .failure(.emptyText):
                return .emptyText
            case .failure(.checklistFull):
                return .checklistFull
            case .success(let item):
                WorkspaceTodoFeature.markUsed()
                return .resolved(
                    windowID: AppDelegate.shared?.windowId(for: tabManager),
                    item: todoItemSnapshot(item),
                    removedCount: 0,
                    checklist: todoChecklistSnapshot(for: workspace)
                )
            }
        }
    }

    func controlWorkspaceTodoSetState(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?,
        stateRaw: String
    ) -> ControlWorkspaceTodoMutationResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            guard let state = WorkspaceChecklistItem.State(rawValue: stateRaw) else {
                return .invalidState(stateRaw)
            }
            guard let item = todoItem(in: workspace, itemID: itemID, itemIndex: itemIndex),
                  workspace.setChecklistItemState(id: item.id, state: state) else {
                return .itemNotFound
            }
            var updated = item
            updated.state = state
            WorkspaceTodoFeature.markUsed()
            return .resolved(
                windowID: AppDelegate.shared?.windowId(for: tabManager),
                item: todoItemSnapshot(updated),
                removedCount: 0,
                checklist: todoChecklistSnapshot(for: workspace)
            )
        }
    }

    func controlWorkspaceTodoEdit(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?,
        text: String
    ) -> ControlWorkspaceTodoMutationResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            guard let normalized = WorkspaceChecklistItem.normalizedText(text) else {
                return .emptyText
            }
            guard let item = todoItem(in: workspace, itemID: itemID, itemIndex: itemIndex),
                  workspace.setChecklistItemText(id: item.id, text: normalized) else {
                return .itemNotFound
            }
            var updated = item
            updated.text = normalized
            WorkspaceTodoFeature.markUsed()
            return .resolved(
                windowID: AppDelegate.shared?.windowId(for: tabManager),
                item: todoItemSnapshot(updated),
                removedCount: 0,
                checklist: todoChecklistSnapshot(for: workspace)
            )
        }
    }

    func controlWorkspaceTodoRemove(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?
    ) -> ControlWorkspaceTodoMutationResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            guard let item = todoItem(in: workspace, itemID: itemID, itemIndex: itemIndex),
                  workspace.removeChecklistItem(id: item.id) else {
                return .itemNotFound
            }
            WorkspaceTodoFeature.markUsed()
            return .resolved(
                windowID: AppDelegate.shared?.windowId(for: tabManager),
                item: todoItemSnapshot(item),
                removedCount: 1,
                checklist: todoChecklistSnapshot(for: workspace)
            )
        }
    }

    func controlWorkspaceTodoMove(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?,
        toIndex: Int
    ) -> ControlWorkspaceTodoMutationResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            guard let item = todoItem(in: workspace, itemID: itemID, itemIndex: itemIndex),
                  workspace.moveChecklistItem(id: item.id, toIndex: toIndex) else {
                return .itemNotFound
            }
            WorkspaceTodoFeature.markUsed()
            return .resolved(
                windowID: AppDelegate.shared?.windowId(for: tabManager),
                item: todoItemSnapshot(item),
                removedCount: 0,
                checklist: todoChecklistSnapshot(for: workspace)
            )
        }
    }

    func controlWorkspaceTodoClear(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoMutationResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            let removedCount = workspace.clearChecklist()
            WorkspaceTodoFeature.markUsed()
            return .resolved(
                windowID: AppDelegate.shared?.windowId(for: tabManager),
                item: nil,
                removedCount: removedCount,
                checklist: todoChecklistSnapshot(for: workspace)
            )
        }
    }

    func controlWorkspaceTodoSet(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        items: [ControlWorkspaceTodoSetItemParam]
    ) -> ControlWorkspaceTodoSetResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            // Validate every raw state/origin up front so the replace stays
            // atomic (nothing mutated on any invalid element).
            var replacements: [WorkspaceChecklistReplacementItem] = []
            replacements.reserveCapacity(items.count)
            for item in items {
                var state: WorkspaceChecklistItem.State?
                if let stateRaw = item.stateRaw {
                    guard let parsed = WorkspaceChecklistItem.State(rawValue: stateRaw) else {
                        return .invalidState(stateRaw)
                    }
                    state = parsed
                }
                var origin: WorkspaceChecklistItem.Origin?
                if let originRaw = item.originRaw {
                    guard let parsed = WorkspaceChecklistItem.Origin(rawValue: originRaw) else {
                        return .invalidOrigin(originRaw)
                    }
                    origin = parsed
                }
                replacements.append(WorkspaceChecklistReplacementItem(
                    id: item.id,
                    text: item.text,
                    state: state,
                    origin: origin
                ))
            }
            switch workspace.replaceChecklist(with: replacements) {
            case .failure(.emptyText(let index)):
                return .emptyText(index: index)
            case .failure(.duplicateId(let index)):
                return .duplicateId(index: index)
            case .failure(.tooManyItems(let count)):
                return .tooManyItems(count: count)
            case .success:
                WorkspaceTodoFeature.markUsed()
                return .resolved(
                    windowID: AppDelegate.shared?.windowId(for: tabManager),
                    checklist: todoChecklistSnapshot(for: workspace)
                )
            }
        }
    }

    func controlWorkspaceTodoOpen(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        requestedFocus: Bool
    ) -> ControlWorkspaceTodoOpenResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            let focus = v2FocusAllowed(requested: requestedFocus)
            if focus {
                v2MaybeFocusWindow(for: tabManager)
                v2MaybeSelectWorkspace(tabManager, workspace: workspace)
            }
            guard let panel = WorkspaceTodoActions.openTodoPane(
                for: workspace,
                focus: focus
            ) else {
                return .openFailed
            }
            return .opened(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: workspace.id,
                paneID: workspace.paneId(forPanelId: panel.id)?.id,
                surfaceID: panel.id
            )
        }
    }
}

// MARK: - Cross-workspace task queue

extension TerminalController: ControlWorkspaceTaskQueueContext {
    func controlWorkspaceTaskQueueList(
        statusRaw: String?,
        workspaceID: UUID?
    ) -> ControlWorkspaceTaskQueueResolution {
        guard let app = AppDelegate.shared else { return .tabManagerUnavailable }
        let workspaces = app.allWorkspacesForAgentTodoRetirement
        let workspacesByID = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = workspaces.flatMap { workspace -> [ControlWorkspaceTaskQueueItem] in
            let windowID = app.tabManagerFor(tabId: workspace.id).flatMap { app.windowId(for: $0) }
            return workspace.todoState.checklist.compactMap { item in
                guard statusRaw == nil || item.state.rawValue == statusRaw else { return nil }
                let projected = queueItem(
                    item,
                    workspace: workspace,
                    windowID: windowID,
                    boundWorkspace: item.boundWorkspaceID.flatMap { workspacesByID[$0] }
                )
                guard workspaceID == nil || projected.workspaceID == workspaceID else { return nil }
                return projected
            }
        }
        return .resolved(items.sorted {
            if $0.state != $1.state { return queueStateRank($0.state) < queueStateRank($1.state) }
            if $0.workspaceTitle != $1.workspaceTitle { return $0.workspaceTitle < $1.workspaceTitle }
            return $0.text.localizedStandardCompare($1.text) == .orderedAscending
        })
    }

    func controlWorkspaceTaskQueueDispatch(
        itemID: UUID,
        routing _: ControlRoutingSelectors
    ) -> ControlWorkspaceTaskQueueDispatchResolution {
        guard let app = AppDelegate.shared else { return .tabManagerUnavailable }
        guard let source = app.allWorkspacesForAgentTodoRetirement.first(where: {
            $0.todoState.checklist.contains(where: { $0.id == itemID })
        }), let item = source.todoState.checklist.first(where: { $0.id == itemID }) else {
            return .notFound
        }
        guard let target = item.dispatchTarget,
              !target.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notDispatchable
        }
        if let boundWorkspaceID = item.boundWorkspaceID {
            let boundWorkspace = app.allWorkspacesForAgentTodoRetirement.first {
                $0.id == boundWorkspaceID
            }
            if let boundWorkspace {
                // A workspace can outlive the process it dispatched. Revalidate
                // the structured PID identities before treating the binding as
                // active; a stale lifecycle/status row must not block retry.
                _ = boundWorkspace.clearStaleAgentPIDs(refreshPorts: false)
                let normalizedAgent = target.agentName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let candidateStatusKeys: Set<String> = if let normalizedAgent,
                                                               !normalizedAgent.isEmpty {
                    [
                        normalizedAgent,
                        FeedCoordinator.lifecycleStatusKey(forSource: normalizedAgent),
                    ]
                } else {
                    []
                }
                let boundWorkspaceIsLive = boundWorkspace.agentPIDs.keys.contains { key in
                    candidateStatusKeys.isEmpty
                        || candidateStatusKeys.contains(boundWorkspace.agentStatusKey(forAgentPIDKey: key))
                }
                if boundWorkspaceIsLive {
                    return .notDispatchable
                }
            }
            // The target is closed or its recorded process is gone. Keep the
            // source row and target configuration, but release the stale
            // binding before creating a replacement workspace.
            guard source.clearChecklistItemBinding(id: itemID) else { return .notFound }
        }
        guard let sourceManager = app.tabManagerFor(tabId: source.id) ?? tabManager else {
            return .tabManagerUnavailable
        }
        var params: [String: Any] = [
            "focus": false,
            "initial_command": target.agentCommand,
            "working_directory": target.workingDirectory ?? source.currentDirectory,
            "eager_load_terminal": false,
        ]
        if let sourceWindowID = app.windowId(for: sourceManager) {
            params["window_id"] = sourceWindowID.uuidString
        }
        guard case .ok(let rawResult) = v2WorkspaceCreate(
            params: params,
            tabManager: sourceManager
        ), let result = rawResult as? [String: Any],
              let createdRaw = result["workspace_id"] as? String,
              let createdID = UUID(uuidString: createdRaw) else {
            return .notDispatchable
        }
        guard source.bindChecklistItem(
            id: itemID,
            toWorkspace: createdID,
            agent: target.agentName,
            at: Date()
        ) else { return .notFound }
        FeedCoordinator.shared.registerDispatchedTask(
            itemID: itemID,
            sourceWorkspaceID: source.id,
            targetWorkspaceID: createdID
        )
        WorkspaceTodoFeature.markUsed()
        let owner = sourceManager
        return .created(
            item: queueItem(
                source.todoState.checklist.first(where: { $0.id == itemID }) ?? item,
                workspace: source,
                windowID: app.windowId(for: owner),
                boundWorkspace: app.tabManagerFor(tabId: createdID)?.tabs.first { $0.id == createdID }
            ),
            createdWorkspaceID: createdID,
            windowID: app.windowId(for: owner)
        )
    }

    func controlWorkspaceTaskQueueReveal(
        itemID: UUID
    ) -> ControlWorkspaceTaskQueueRevealResolution {
        guard let app = AppDelegate.shared else { return .tabManagerUnavailable }
        guard let workspace = app.allWorkspacesForAgentTodoRetirement.first(where: {
            $0.todoState.checklist.contains(where: { $0.id == itemID })
        }), let item = workspace.todoState.checklist.first(where: { $0.id == itemID }) else {
            return .notFound
        }
        // Open the owning workspace's todo surface without focusing it. This
        // is the concrete reveal action; the notification lets a sidebar host
        // scroll its row as well. Neither path selects a workspace or activates
        // a window.
        let displayedWorkspace = item.boundWorkspaceID.flatMap { boundID in
            app.allWorkspacesForAgentTodoRetirement.first { $0.id == boundID }
        } ?? workspace
        guard let workspaceManager = app.tabManagerFor(tabId: workspace.id) ?? tabManager else {
            return .tabManagerUnavailable
        }
        _ = WorkspaceTodoActions.openTodoPane(for: displayedWorkspace, focus: false)
        NotificationCenter.default.post(
            name: .workspaceTaskQueueRevealRequested,
            object: nil,
            userInfo: ["workspaceId": displayedWorkspace.id]
        )
        return .revealed(
            item: queueItem(
                item,
                workspace: workspace,
                windowID: app.windowId(for: workspaceManager),
                boundWorkspace: item.boundWorkspaceID.flatMap { boundID in
                    app.allWorkspacesForAgentTodoRetirement.first { $0.id == boundID }
                }
            )
        )
    }

    func controlWorkspaceTaskQueueSetTarget(
        itemID: UUID,
        workingDirectory: String?,
        agentCommand: String?,
        agentName: String?
    ) -> ControlWorkspaceTaskQueueTargetResolution {
        guard let app = AppDelegate.shared else { return .tabManagerUnavailable }
        guard let workspace = app.allWorkspacesForAgentTodoRetirement.first(where: {
            $0.todoState.checklist.contains(where: { $0.id == itemID })
        }), let item = workspace.todoState.checklist.first(where: { $0.id == itemID }) else {
            return .notFound
        }
        let normalizedCommand = agentCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: WorkspaceTaskDispatchTarget?
        if let normalizedCommand, !normalizedCommand.isEmpty {
            target = WorkspaceTaskDispatchTarget(
                workingDirectory: workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                agentCommand: normalizedCommand,
                agentName: agentName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        } else {
            target = nil
        }
        guard let workspaceManager = app.tabManagerFor(tabId: workspace.id) ?? tabManager else {
            return .tabManagerUnavailable
        }
        guard workspace.setChecklistItemDispatchTarget(id: itemID, target: target) else {
            return .notFound
        }
        WorkspaceTodoFeature.markUsed()
        return .updated(
            item: queueItem(
                workspace.todoState.checklist.first(where: { $0.id == itemID }) ?? item,
                workspace: workspace,
                windowID: app.windowId(for: workspaceManager),
                boundWorkspace: item.boundWorkspaceID.flatMap { boundID in
                    app.allWorkspacesForAgentTodoRetirement.first { $0.id == boundID }
                }
            )
        )
    }

    private func queueItem(
        _ item: WorkspaceChecklistItem,
        workspace: Workspace,
        windowID: UUID?,
        boundWorkspace: Workspace?
    ) -> ControlWorkspaceTaskQueueItem {
        let boundManager = boundWorkspace.flatMap { AppDelegate.shared?.tabManagerFor(tabId: $0.id) }
        let boundWindowID = boundManager.flatMap { AppDelegate.shared?.windowId(for: $0) }
        return ControlWorkspaceTaskQueueItem(
            id: item.id,
            text: item.text,
            state: item.state.rawValue,
            workspaceID: workspace.id,
            workspaceTitle: workspace.title,
            windowID: windowID,
            owningAgent: item.boundAgent ?? item.agentTaskRef?.workstreamId ?? item.dispatchTarget?.agentName,
            lastActivityAt: item.lastActivityAt,
            targetWorkingDirectory: item.dispatchTarget?.workingDirectory,
            targetAgentCommand: item.dispatchTarget?.agentCommand,
            targetAgentName: item.dispatchTarget?.agentName,
            boundWorkspaceID: item.boundWorkspaceID,
            boundWorkspaceTitle: boundWorkspace?.title,
            boundWindowID: boundWindowID
        )
    }

    private func queueStateRank(_ raw: String) -> Int {
        switch raw {
        case "in-progress": 0
        case "pending": 1
        case "completed": 2
        default: 3
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Notification.Name {
    /// Posted whenever a workspace checklist changes, allowing the queue view
    /// to refresh its projection without polling or selecting a workspace.
    static let workspaceTaskQueueDidChange = Notification.Name(
        "cmux.workspaceTaskQueueDidChange"
    )

    /// Requests a non-focus-changing queue/sidebar reveal for one workspace.
    static let workspaceTaskQueueRevealRequested = Notification.Name(
        "cmux.workspaceTaskQueueRevealRequested"
    )
}
