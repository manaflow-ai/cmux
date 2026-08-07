import AppKit

@MainActor
struct MainWindowRouteSnapshot {
    let windowId: UUID
    let tabManager: TabManager
    let window: NSWindow?
    let sidebar: SidebarState
    let sidebarSelection: SidebarSelectionState
    let dock: MainWindowRouteDockState?

    /// Hashes only the bounded workspace metadata that can change which routes
    /// session persistence selects. Full panel and notification state is
    /// reserved for the persisted-window projection.
    func combineAutosaveSelectionMetadata(into hasher: inout Hasher) {
        hasher.combine(windowId)
        hasher.combine(dock != nil)
        hasher.combine(tabManager.tabs.count)
        for workspace in tabManager.tabs.prefix(
            SessionPersistencePolicy.maxWorkspacesPerWindow
        ) {
            hasher.combine(workspace.id)
            hasher.combine(workspace.isRestorableInSessionSnapshot)
            hasher.combine(workspace.isRemoteTmuxMirror)
            hasher.combine(workspace.currentDirectory)
            hasher.combine(workspace.customTitle)
            hasher.combine(workspace.customDescription)
            hasher.combine(workspace.customColor)
            hasher.combine(workspace.isPinned)
            hasher.combine(workspace.groupId)
            hasher.combine(workspace.panels.count)
            hasher.combine(workspace.statusEntries.count)
            hasher.combine(workspace.logEntries.count)
            hasher.combine(workspace.progress != nil)
            hasher.combine(workspace.gitBranch != nil)
        }
    }
}
