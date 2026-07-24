import AppKit

extension AppDelegate {
    /// Restores the newest restorable workspace record without consuming tab or window history.
    @discardableResult
    func reopenMostRecentlyClosedWorkspace(
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        ClosedItemHistoryStore.shared.restoreFirstRestorable(
            newerThan: nil,
            matching: { entry in
                if case .workspace = entry {
                    return true
                }
                return false
            },
            using: { entry in
                guard case .workspace(let workspaceEntry) = entry else { return false }
                let manager =
                    workspaceEntry.windowId.flatMap { self.tabManagerFor(windowId: $0) }
                    ?? preferredTabManager
                    ?? self.tabManager
                guard let manager, manager.restoreClosedWorkspace(workspaceEntry) else {
                    return false
                }
                if shouldActivate, let windowId = self.windowId(for: manager) {
                    _ = self.focusMainWindow(windowId: windowId)
                }
                return true
            }
        )
    }
}

extension TabManager {
    /// Reopens the newest closed workspace additively in this manager.
    @discardableResult
    func reopenMostRecentlyClosedWorkspace(
        from historyStore: ClosedItemHistoryStore = .shared
    ) -> Bool {
        if historyStore === ClosedItemHistoryStore.shared,
           let appDelegate = AppDelegate.shared {
            return appDelegate.reopenMostRecentlyClosedWorkspace(preferredTabManager: self)
        }

        return historyStore.restoreFirstRestorable(
            newerThan: nil,
            matching: { entry in
                if case .workspace = entry {
                    return true
                }
                return false
            },
            using: { entry in
                guard case .workspace(let workspaceEntry) = entry else { return false }
                return self.restoreClosedWorkspace(workspaceEntry)
            }
        )
    }
}
