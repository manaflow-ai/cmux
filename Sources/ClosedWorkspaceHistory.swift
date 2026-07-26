import AppKit

extension ClosedItemHistoryStore {
    /// Restores the newest restorable workspace without consuming newer panel or window records.
    @discardableResult
    func restoreMostRecentlyClosedWorkspace(
        using restore: (ClosedWorkspaceHistoryEntry) -> Bool
    ) -> Bool {
        restoreFirstRestorable(
            newerThan: nil,
            matching: { entry in
                if case .workspace = entry {
                    return true
                }
                return false
            },
            using: { entry in
                guard case .workspace(let workspaceEntry) = entry else { return false }
                return restore(workspaceEntry)
            }
        )
    }
}

extension AppDelegate {
    /// Restores the newest restorable workspace record without consuming tab or window history.
    @discardableResult
    func reopenMostRecentlyClosedWorkspace(
        from historyStore: ClosedItemHistoryStore = .shared,
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        historyStore.restoreMostRecentlyClosedWorkspace { workspaceEntry in
            let manager =
                preferredTabManager
                ?? workspaceEntry.windowId.flatMap { self.tabManagerFor(windowId: $0) }
                ?? self.tabManager
            guard let manager,
                  manager.restoreClosedWorkspace(
                    workspaceEntry,
                    excludingStableIdentities: liveStableIdentitySet(
                        preferredTabManager: preferredTabManager
                    ),
                    excludingWorkspaceIds: liveWorkspaceIdSet(
                        preferredTabManager: preferredTabManager
                    )
                  )
            else {
                return false
            }
            if shouldActivate, let windowId = self.windowId(for: manager) {
                _ = self.focusMainWindow(windowId: windowId)
            }
            return true
        }
    }
}

extension TabManager {
    /// Reopens the newest closed workspace additively in this manager.
    @discardableResult
    func reopenMostRecentlyClosedWorkspace(
        from historyStore: ClosedItemHistoryStore = .shared
    ) -> Bool {
        historyStore.restoreMostRecentlyClosedWorkspace { workspaceEntry in
            restoreClosedWorkspace(workspaceEntry)
        }
    }
}
