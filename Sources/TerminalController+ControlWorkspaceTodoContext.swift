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
