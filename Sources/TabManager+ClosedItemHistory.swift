extension TabManager {
    func reopenMostRecentlyClosedItemFromStore() -> ClosedItemHistoryRestoreResult {
        ClosedItemHistoryStore.shared.restoreFirstRestorableResult { entry in
            switch entry {
            case .panel(let panelEntry):
                return restoreClosedPanel(panelEntry)
            case .workspace(let workspaceEntry):
                return restoreClosedWorkspace(workspaceEntry)
            case .window:
                return false
            }
        }
    }
}
