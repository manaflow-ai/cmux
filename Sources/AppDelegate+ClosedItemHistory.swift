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
            ClosedItemHistoryStore.shared.restoreFirstRestorableRef(
                newerThan: cutoff,
                excluding: failedStoreRecordIds,
                onFailure: { failedStoreRecordIds.insert($0) },
                using: { record in
                    self.restoreClosedItem(
                        record.entry,
                        preferredTabManager: preferredTabManager,
                        shouldActivate: shouldActivate
                    )
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
                ClosedItemHistoryStore.shared.clearRedoTarget()
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
        let undoableOperation = ClosedItemHistoryStore.shared.firstUndoableOperation()
        let legacyManagers = recentlyClosedLegacyBrowserManagers(preferredTabManager: preferredTabManager)
        if let legacyManager = legacyManagers.first,
           let legacyClosedAt = legacyManager.mostRecentLegacyClosedBrowserPanelClosedAt(),
           undoableOperation.map({ legacyClosedAt > $0.closedAt }) ?? true,
           legacyManager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack() {
            ClosedItemHistoryStore.shared.clearRedoTarget()
            return true
        }
        guard let op = undoableOperation else {
            // Everything in the store is already live. Fall back to the legacy
            // browser-tab stack only (never re-restore a store entry, which would
            // duplicate something already on screen).
            for manager in legacyManagers {
                if manager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack() {
                    ClosedItemHistoryStore.shared.clearRedoTarget()
                    return true
                }
            }
            return false
        }
        let unrestoredItems = op.items.filter { !$0.isRestored }
        var restoredCount = 0
        for item in op.items where !item.isRestored {
            if reopenClosedHistoryItem(
                id: item.id,
                preferredTabManager: preferredTabManager,
                shouldActivate: shouldActivate
            ) {
                restoredCount += 1
            }
        }
        if restoredCount > 0 {
            ClosedItemHistoryStore.shared.setLastRestoredOperation(op.id)
        }
        return restoredCount == unrestoredItems.count
    }

    /// Op-atomic redo: re-closes the live items of the most recently restored
    /// operation, re-grouped under one new operation so a subsequent undo brings
    /// them back together. Best-effort; falls back to single-item redo.
    @discardableResult
    func redoLastDestructiveAction(preferredTabManager: TabManager? = nil) -> Bool {
        guard let opId = ClosedItemHistoryStore.shared.lastRestoredOperationId else {
            return redoLastReopen(preferredTabManager: preferredTabManager)
        }
        let liveRecords = ClosedItemHistoryStore.shared.recordsForOperation(opId).compactMap { record -> (ClosedItemHistoryRecord, ReopenedItemRef)? in
            guard let ref = ClosedItemHistoryStore.shared.restoredRef(for: record.id),
                  closedItemTargetIsLive(ref) else { return nil }
            return (record, ref)
        }
        guard !liveRecords.isEmpty else {
            ClosedItemHistoryStore.shared.setLastRestoredOperation(nil)
            return redoLastReopen(preferredTabManager: preferredTabManager)
        }
        let redoOperationId = UUID()
        var closedCount = 0
        for (_, ref) in liveRecords where closeReopenedRef(ref, operationId: redoOperationId) {
            closedCount += 1
        }
        let closedAll = closedCount == liveRecords.count
        ClosedItemHistoryStore.shared.setLastRestoredOperation(closedAll ? nil : opId)
        return closedAll
    }

    @discardableResult
    private func closeReopenedRef(_ ref: ReopenedItemRef, operationId: UUID) -> Bool {
        switch ref {
        case .panel(let workspaceId, let panelId):
            guard let manager = tabManagerFor(tabId: workspaceId),
                  let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else { return false }
            return workspace.closePanel(panelId, operationId: operationId)
        case .workspace(let workspaceId):
            guard let manager = tabManagerFor(tabId: workspaceId),
                  let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else { return false }
            return manager.closeWorkspaceForHistoryRedo(workspace, operationId: operationId)
        case .window(let windowId):
            return closeMainWindow(windowId: windowId, operationId: operationId)
        }
    }

    /// Re-closes the item most recently reopened from history ("redo" of an
    /// undo-close). Re-closing records the close again, so the item returns to
    /// history and can be reopened once more. Best-effort: if the reopened item
    /// is already gone, the redo target is cleared and this returns false.
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
            return workspace.closePanel(panelId, operationId: UUID())
        case .workspace(let workspaceId):
            guard let manager = tabManagerFor(tabId: workspaceId) ?? preferredTabManager ?? tabManager,
                  let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
                ClosedItemHistoryStore.shared.clearRedoTarget()
                return false
            }
            return manager.closeWorkspaceForHistoryRedo(workspace, operationId: UUID())
        case .window(let windowId):
            guard closeMainWindow(windowId: windowId) else {
                ClosedItemHistoryStore.shared.clearRedoTarget()
                return false
            }
            return true
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
