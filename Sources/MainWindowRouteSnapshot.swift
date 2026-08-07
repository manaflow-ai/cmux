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
    func combineAutosaveSelectionMetadata(
        into hasher: inout Hasher,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex
    ) {
        hasher.combine(windowId)
        hasher.combine(dock != nil)
        tabManager.combineSessionPersistenceSelectionMetadata(
            into: &hasher,
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex
        )
    }
}
