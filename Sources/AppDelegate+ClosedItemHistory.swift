import AppKit

extension AppDelegate {
    func clearRecentlyClosedHistory(preferredTabManager: TabManager? = nil) {
        ClosedItemHistoryStore.shared.removeAll()

        var clearedManagers: Set<ObjectIdentifier> = []
        func clear(_ manager: TabManager?) {
            guard let manager else { return }
            guard clearedManagers.insert(ObjectIdentifier(manager)).inserted else { return }
            manager.clearRecentlyClosedBrowserPanelHistory()
        }

        clear(preferredTabManager)
        clear(tabManager)
        for context in mainWindowContexts.values {
            clear(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            clear(route.tabManager)
        }
    }

    @discardableResult
    func reopenMostRecentlyClosedItem(
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        var failedStoreRecordIds: Set<UUID> = []
        let restoreStoreItem: (Date?) -> Bool = { cutoff in
            ClosedItemHistoryStore.shared.restoreFirstRestorable(
                newerThan: cutoff,
                excluding: failedStoreRecordIds,
                onFailure: { failedStoreRecordIds.insert($0) },
                using: { entry in
                    self.restoreClosedItem(
                        entry,
                        preferredTabManager: preferredTabManager,
                        shouldActivate: shouldActivate
                    ) != nil
                }
            )
        }

        for manager in recentlyClosedLegacyBrowserManagers(preferredTabManager: preferredTabManager) {
            guard let closedAt = manager.mostRecentLegacyClosedBrowserPanelClosedAt() else {
                continue
            }
            if restoreStoreItem(closedAt) {
                return true
            }
            if manager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack() {
                return true
            }
        }

        return restoreStoreItem(nil)
    }

    private func recentlyClosedLegacyBrowserManagers(preferredTabManager: TabManager?) -> [TabManager] {
        var managers: [TabManager] = []
        var seen: Set<ObjectIdentifier> = []

        func append(_ manager: TabManager?) {
            guard let manager else { return }
            guard manager.mostRecentLegacyClosedBrowserPanelClosedAt() != nil else { return }
            guard seen.insert(ObjectIdentifier(manager)).inserted else { return }
            managers.append(manager)
        }

        append(preferredTabManager)
        append(tabManager)
        for context in mainWindowContexts.values {
            append(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            append(route.tabManager)
        }

        return managers.sorted { lhs, rhs in
            let lhsDate = lhs.mostRecentLegacyClosedBrowserPanelClosedAt() ?? .distantPast
            let rhsDate = rhs.mostRecentLegacyClosedBrowserPanelClosedAt() ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    @discardableResult
    private func restoreClosedItem(
        _ entry: ClosedItemHistoryEntry,
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool
    ) -> ReopenedItemRef? {
        switch entry {
        case .panel(let panelEntry):
            let manager =
                tabManagerFor(tabId: panelEntry.workspaceId)
                ?? preferredTabManager
                ?? tabManager
            guard let manager, let panelId = manager.restoreClosedPanel(panelEntry) else {
                return nil
            }
            ClosedItemHistoryStore.shared.noteReopened(
                .panel(workspaceId: panelEntry.workspaceId, panelId: panelId)
            )
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return .panel(workspaceId: panelEntry.workspaceId, panelId: panelId)
        case .workspace(let workspaceEntry):
            let manager =
                workspaceEntry.windowId.flatMap { tabManagerFor(windowId: $0) }
                ?? preferredTabManager
                ?? tabManager
            guard let manager, let restoredWorkspaceId = manager.restoreClosedWorkspace(workspaceEntry) else {
                return nil
            }
            ClosedItemHistoryStore.shared.noteReopened(.workspace(workspaceId: restoredWorkspaceId))
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return .workspace(workspaceId: restoredWorkspaceId)
        case .window(let windowEntry):
            var restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]] = []
            var restoredTabManager: TabManager?
            var windowSnapshot = windowEntry.snapshot
            if windowSnapshot.windowId == nil {
                windowSnapshot.windowId = windowEntry.windowId
            }
            let originalWindowId = windowSnapshot.windowId
            let originalWorkspaceIdsByIndex = windowSnapshot.tabManager.workspaces.enumerated().map { index, workspaceSnapshot -> UUID? in
                if let workspaceId = workspaceSnapshot.workspaceId {
                    return workspaceId
                }
                guard windowEntry.workspaceIds.indices.contains(index) else { return nil }
                return windowEntry.workspaceIds[index]
            }
            let windowId = createMainWindow(
                sessionWindowSnapshot: windowSnapshot,
                shouldActivate: shouldActivate,
                remapClosedPanelHistoryFromSessionSnapshot: false,
                restoredSessionSnapshotHandler: { panelIdsByWorkspaceIndex, tabManager in
                    restoredPanelIdsByWorkspaceIndex = panelIdsByWorkspaceIndex
                    restoredTabManager = tabManager
                }
            )
            let hasLivePanels = restoredTabManager?.tabs.contains { !$0.panels.isEmpty } == true
            guard ClosedWindowRestoreValidation.hasUsableRestoredContent(
                snapshot: windowEntry.snapshot,
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex,
                hasLivePanels: hasLivePanels
            ) else {
                if let originalWindowId {
                    ClosedItemHistoryStore.shared.remapWorkspaceWindowIds(from: windowId, to: originalWindowId)
                    ClosedItemHistoryStore.shared.flushPendingSaves()
                }
                discardMainWindowWithoutClosedHistory(windowId: windowId)
                return nil
            }
            restoredTabManager?.remapClosedPanelHistoryAfterSessionRestore(
                originalWorkspaceIds: originalWorkspaceIdsByIndex,
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex
            )
            ClosedItemHistoryStore.shared.noteReopened(.window(windowId: windowId))
            return .window(windowId: windowId)
        }
    }

    /// Reopens a specific history entry without removing it. The closed-item
    /// history is an immutable, append-only log (browser-history style): reopening
    /// leaves the entry in place, and closing the reopened item later appends a
    /// fresh entry. Use the explicit "Remove from History" action to delete an
    /// entry, or Cmd+Z (``reopenMostRecentlyClosedItem(preferredTabManager:shouldActivate:)``)
    /// for the consuming undo-stack behavior.
    @discardableResult
    func reopenClosedHistoryItem(
        id: UUID,
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        guard let record = ClosedItemHistoryStore.shared.record(id: id) else {
            return false
        }

        guard let ref = restoreClosedItem(
            record.entry,
            preferredTabManager: preferredTabManager,
            shouldActivate: shouldActivate
        ) else {
            return false
        }
        // Mark restored so the immutable log shows it as already-open and
        // restore-remaining / undo skip it (single liveness source of truth).
        ClosedItemHistoryStore.shared.markRestored(recordId: record.id, ref: ref)
        ClosedItemHistoryStore.shared.setLastRestoredOperation(record.operationId)
        return true
    }

    /// Op-atomic undo: restores the most recent destructive action (operation)
    /// whose items aren't already live, as a unit and non-destructively (the
    /// entries stay in the immutable log, greyed). Walks back monotonically: the
    /// next undo targets the next-older operation with remaining items. Falls back
    /// to the legacy browser-tab stack when no grouped operation is pending.
    @discardableResult
    func undoLastDestructiveAction(
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = false
    ) -> Bool {
        let operations = ClosedItemHistoryStore.shared.operationSnapshot()
        guard let op = operations.first(where: { !$0.isFullyRestored }) else {
            // Everything in the store is already live. Fall back to the legacy
            // browser-tab stack only (never re-restore a store entry, which would
            // duplicate something already on screen).
            for manager in recentlyClosedLegacyBrowserManagers(preferredTabManager: preferredTabManager) {
                if manager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack() {
                    return true
                }
            }
            return false
        }
        var restoredAny = false
        for item in op.items where !item.isRestored {
            if reopenClosedHistoryItem(
                id: item.id,
                preferredTabManager: preferredTabManager,
                shouldActivate: shouldActivate
            ) {
                restoredAny = true
            }
        }
        if restoredAny {
            ClosedItemHistoryStore.shared.setLastRestoredOperation(op.id)
        }
        return restoredAny
    }

    /// Op-atomic redo: re-closes the live items of the most recently restored
    /// operation, re-grouped under one new operation so a subsequent undo brings
    /// them back together. Best-effort; falls back to single-item redo.
    @discardableResult
    func redoLastDestructiveAction(preferredTabManager: TabManager? = nil) -> Bool {
        guard let opId = ClosedItemHistoryStore.shared.lastRestoredOperationId else {
            return redoLastReopen(preferredTabManager: preferredTabManager)
        }
        let liveRefs = ClosedItemHistoryStore.shared.recordsForOperation(opId).compactMap { record -> ReopenedItemRef? in
            guard let ref = ClosedItemHistoryStore.shared.restoredRef(for: record.id),
                  closedItemTargetIsLive(ref) else { return nil }
            return ref
        }
        guard !liveRefs.isEmpty else {
            ClosedItemHistoryStore.shared.setLastRestoredOperation(nil)
            return redoLastReopen(preferredTabManager: preferredTabManager)
        }
        let redoOperationId = UUID()
        var closedAny = false
        for ref in liveRefs where closeReopenedRef(ref, operationId: redoOperationId) {
            closedAny = true
        }
        ClosedItemHistoryStore.shared.setLastRestoredOperation(nil)
        return closedAny
    }

    @discardableResult
    private func closeReopenedRef(_ ref: ReopenedItemRef, operationId: UUID) -> Bool {
        switch ref {
        case .panel(let workspaceId, let panelId):
            guard let manager = tabManagerFor(tabId: workspaceId),
                  let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else { return false }
            return workspace.closePanel(panelId)
        case .workspace(let workspaceId):
            guard let manager = tabManagerFor(tabId: workspaceId),
                  let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else { return false }
            manager.closeWorkspace(workspace, operationId: operationId)
            return !manager.tabs.contains(where: { $0.id == workspaceId })
        case .window:
            return false
        }
    }

    /// Re-closes the item most recently reopened from history ("redo" of an
    /// undo-close). Re-closing records the close again, so the item returns to
    /// history and can be reopened once more. Best-effort: if the reopened item
    /// is already gone, the redo target is cleared and this returns false.
    /// Panels and workspaces only; window reopens are not redoable.
    @discardableResult
    func redoLastReopen(preferredTabManager: TabManager? = nil) -> Bool {
        guard let target = ClosedItemHistoryStore.shared.redoTarget else { return false }
        switch target {
        case .panel(let workspaceId, let panelId):
            guard let manager = tabManagerFor(tabId: workspaceId) ?? preferredTabManager ?? tabManager,
                  let workspace = manager.tabs.first(where: { $0.id == workspaceId }),
                  workspace.panels[panelId] != nil else {
                ClosedItemHistoryStore.shared.clearRedoTarget()
                return false
            }
            return workspace.closePanel(panelId)
        case .workspace(let workspaceId):
            guard let manager = tabManagerFor(tabId: workspaceId) ?? preferredTabManager ?? tabManager,
                  let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
                ClosedItemHistoryStore.shared.clearRedoTarget()
                return false
            }
            manager.closeWorkspace(workspace, recordHistory: true)
            return !manager.tabs.contains(where: { $0.id == workspaceId })
        case .window:
            // Window re-close is not supported for redo; clear the target.
            ClosedItemHistoryStore.shared.clearRedoTarget()
            return false
        }
    }

    /// The single liveness source of truth for "already restored": is the live
    /// item a reopen produced still present? Wired into `ClosedItemHistoryStore`
    /// at launch. Best-effort scan over the active tab managers; only called on
    /// snapshot / undo / redo paths, never a hot path.
    func closedItemTargetIsLive(_ ref: ReopenedItemRef) -> Bool {
        switch ref {
        case .panel(let workspaceId, let panelId):
            guard let manager = tabManagerFor(tabId: workspaceId),
                  let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
                return false
            }
            return workspace.panels[panelId] != nil
        case .workspace(let workspaceId):
            return tabManagerFor(tabId: workspaceId) != nil
        case .window(let windowId):
            return tabManagerFor(windowId: windowId) != nil
        }
    }

    private func activateMainWindowIfNeeded(for manager: TabManager, shouldActivate: Bool) {
        guard shouldActivate,
              let windowId = windowId(for: manager) else {
            return
        }
        _ = focusMainWindow(windowId: windowId)
    }
}
