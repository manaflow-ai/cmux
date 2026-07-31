import AppKit

extension AppDelegate {
    func clearRecentlyClosedHistory(preferredTabManager: TabManager? = nil) {
        ClosedItemHistoryStore.shared.removeAll()

        for manager in liveWorkspaceIdentityTabManagers(preferredTabManager: preferredTabManager) {
            manager.clearRecentlyClosedBrowserPanelHistory()
        }
    }

    @discardableResult
    func reopenMostRecentlyClosedItem(
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = false
    ) -> Bool {
        var failedStoreRecordIds: Set<UUID> = []
        let restoreStoreItem: (Date?) -> ClosedItemHistoryRestoreAttempt = { cutoff in
            ClosedItemHistoryStore.shared.attemptFirstRestorable(
                newerThan: cutoff,
                excluding: failedStoreRecordIds,
                onFailure: { failedStoreRecordIds.insert($0) },
                using: { record in
                    self.attemptRestoreClosedItem(
                        record,
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
            if restoreStoreItem(closedAt).wasAccepted {
                return true
            }
            if manager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack() {
                return true
            }
        }

        return restoreStoreItem(nil).wasAccepted
    }

    private func recentlyClosedLegacyBrowserManagers(preferredTabManager: TabManager?) -> [TabManager] {
        let managers = liveWorkspaceIdentityTabManagers(preferredTabManager: preferredTabManager)
            .filter { $0.mostRecentLegacyClosedBrowserPanelClosedAt() != nil }
        return managers.sorted { lhs, rhs in
            let lhsDate = lhs.mostRecentLegacyClosedBrowserPanelClosedAt() ?? .distantPast
            let rhsDate = rhs.mostRecentLegacyClosedBrowserPanelClosedAt() ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func attemptRestoreClosedItem(
        _ record: ClosedItemHistoryRecord,
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool
    ) -> ClosedItemHistoryRestoreAttempt {
        switch record.entry {
        case .panel(let panelEntry):
            let manager =
                tabManagerFor(tabId: panelEntry.workspaceId)
                ?? preferredTabManager
                ?? tabManager
            guard let manager, manager.restoreClosedPanel(panelEntry) else {
                return .failed
            }
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return .restored
        case .remoteTmuxMirror(let remoteEntry):
            if let restored = remoteTmuxController.restoreClosedMirrorIfAlreadyLive(
                remoteEntry,
                shouldActivate: shouldActivate
            ) {
                return restored ? .restored : .failed
            }
            Task { @MainActor in
                let succeeded = await remoteTmuxController.restoreClosedMirror(
                    remoteEntry,
                    preferredTabManager: preferredTabManager,
                    shouldActivate: shouldActivate
                )
                ClosedItemHistoryStore.shared.completePendingRestore(
                    id: record.id,
                    succeeded: succeeded
                )
                if !succeeded {
                    NSSound.beep()
                }
            }
            return .pending
        case .workspace(let workspaceEntry):
            let manager =
                workspaceEntry.windowId.flatMap { tabManagerFor(windowId: $0) }
                ?? preferredTabManager
                ?? tabManager
            guard let manager,
                  manager.restoreClosedWorkspace(
                    workspaceEntry,
                    excludingStableIdentities: liveStableIdentitySet(preferredTabManager: preferredTabManager),
                    excludingWorkspaceIds: liveWorkspaceIdSet(preferredTabManager: preferredTabManager)
                  )
            else {
                return .failed
            }
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return .restored
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
            let excludedStableIdentities = liveStableIdentitySet()
            let excludedWorkspaceIds = liveWorkspaceIdSet()
            let windowId = createMainWindow(
                sessionWindowSnapshot: windowSnapshot,
                shouldActivate: shouldActivate,
                remapClosedPanelHistoryFromSessionSnapshot: false,
                excludingStableIdentitiesFromSessionSnapshot: excludedStableIdentities,
                excludingWorkspaceIdsFromSessionSnapshot: excludedWorkspaceIds,
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
                return .failed
            }
            restoredTabManager?.remapClosedPanelHistoryAfterSessionRestore(
                originalWorkspaceIds: originalWorkspaceIdsByIndex,
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex,
                ambiguousOriginalWorkspaceIds: excludedWorkspaceIds
            )
            return .restored
        }
    }

    @discardableResult
    func reopenClosedHistoryItem(
        id: UUID,
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = false
    ) -> Bool {
        ClosedItemHistoryStore.shared.attemptRestore(id: id) { record in
            attemptRestoreClosedItem(
                record,
                preferredTabManager: preferredTabManager,
                shouldActivate: shouldActivate
            )
        }.wasAccepted
    }

    private func activateMainWindowIfNeeded(for manager: TabManager, shouldActivate: Bool) {
        guard shouldActivate,
              let windowId = windowId(for: manager) else {
            return
        }
        _ = focusMainWindow(windowId: windowId)
    }
}
