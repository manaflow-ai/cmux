import AppKit

extension AppDelegate {
    @discardableResult
    func reopenMostRecentlyClosedItem(
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        if ClosedItemHistoryStore.shared.restoreFirstRestorable(using: { entry in
            restoreClosedItem(
                entry,
                preferredTabManager: preferredTabManager,
                shouldActivate: shouldActivate
            )
        }) {
            return true
        }

        if preferredTabManager?.reopenMostRecentlyClosedBrowserPanelFromLegacyStack() == true {
            return true
        }
        if let tabManager,
           tabManager !== preferredTabManager,
           tabManager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack() {
            return true
        }

        return false
    }

    @discardableResult
    func reopenClosedHistoryItem(
        id: UUID,
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        guard let removed = ClosedItemHistoryStore.shared.removeRecord(id: id) else {
            return false
        }

        if restoreClosedItem(
            removed.record.entry,
            preferredTabManager: preferredTabManager,
            shouldActivate: shouldActivate
        ) {
            return true
        }

        ClosedItemHistoryStore.shared.insert(removed.record, at: removed.index)
        return false
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
            guard let manager, manager.restoreClosedPanel(panelEntry) else {
                return false
            }
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return true
        case .workspace(let workspaceEntry):
            let manager =
                workspaceEntry.windowId.flatMap { tabManagerFor(windowId: $0) }
                ?? preferredTabManager
                ?? tabManager
            guard let manager, manager.restoreClosedWorkspace(workspaceEntry) else {
                return false
            }
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return true
        case .window(let windowEntry):
            _ = createMainWindow(
                sessionWindowSnapshot: windowEntry.snapshot,
                shouldActivate: shouldActivate,
                closedWindowHistoryWorkspaceIds: windowEntry.workspaceIds
            )
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
