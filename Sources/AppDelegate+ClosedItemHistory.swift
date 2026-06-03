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
    ) -> Bool {
        switch entry {
        case .panel(let panelEntry):
            let manager =
                tabManagerFor(tabId: panelEntry.workspaceId)
                ?? preferredTabManager
                ?? tabManager
            guard let manager, let panelId = manager.restoreClosedPanel(panelEntry) else {
                return false
            }
            ClosedItemHistoryStore.shared.noteReopened(
                .panel(workspaceId: panelEntry.workspaceId, panelId: panelId)
            )
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return true
        case .workspace(let workspaceEntry):
            let manager =
                workspaceEntry.windowId.flatMap { tabManagerFor(windowId: $0) }
                ?? preferredTabManager
                ?? tabManager
            guard let manager, let restoredWorkspaceId = manager.restoreClosedWorkspace(workspaceEntry) else {
                return false
            }
            ClosedItemHistoryStore.shared.noteReopened(.workspace(workspaceId: restoredWorkspaceId))
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return true
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
                return false
            }
            restoredTabManager?.remapClosedPanelHistoryAfterSessionRestore(
                originalWorkspaceIds: originalWorkspaceIdsByIndex,
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex
            )
            return true
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

        return restoreClosedItem(
            record.entry,
            preferredTabManager: preferredTabManager,
            shouldActivate: shouldActivate
        )
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
            return true
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
