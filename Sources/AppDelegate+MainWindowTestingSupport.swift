#if DEBUG
import AppKit
import CmuxTerminal

/// Test-only main-window context seams, isolated from the production
/// AppDelegate source per the repo's debug-seam policy. Tests register a
/// windowless context (and tear it down through the same removal path the
/// real window-close flow uses, including per-window Dock teardown).
extension AppDelegate {
    @discardableResult
    func registerMainWindowContextForTesting(
        windowId: UUID = UUID(),
        tabManager: TabManager,
        cmuxConfigStore: CmuxConfigStore? = nil,
        fileExplorerState: FileExplorerState? = nil
    ) -> UUID {
        tabManager.windowId = windowId
        mainWindowContexts[ObjectIdentifier(tabManager)] = MainWindowContext(
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore,
            window: nil
        )
        ensureMobileWorkspaceListObserver(for: tabManager)
        notifyMainWindowContextsDidChange()
        return windowId
    }

    func unregisterMainWindowContextForTesting(windowId: UUID) {
        mainWindowContexts.values.filter { $0.windowId == windowId }.forEach { discardOrphanedMainWindowContext($0, allowWindowlessFallback: true) }
    }
}
#endif
