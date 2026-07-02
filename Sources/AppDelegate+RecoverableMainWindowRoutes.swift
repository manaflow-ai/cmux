import AppKit
import CmuxTerminalCore
import CmuxWindowing

// The retire sweep is the MainWindowRouteRetiring witness: the terminal
// surface registry (CmuxTerminalEngine) calls it through the seam instead of
// reaching up to AppDelegate.shared.
extension AppDelegate: MainWindowRouteRetiring {}

extension AppDelegate {
    func retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(reason: String) {
        windowRegistry.retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(reason: reason)
    }

    func forgetRecoverableMainWindowRoute(windowId: UUID) {
        windowRegistry.forgetRecoverableMainWindowRoute(windowId: windowId)
    }

    func rememberRecoverableMainWindowRoute(windowId: UUID, tabManager: TabManager, window: NSWindow?) {
        windowRegistry.rememberRecoverableMainWindowRoute(windowId: windowId, tabManager: tabManager, window: window)
    }

    func recoverableMainWindowRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        windowRegistry.recoverableMainWindowRoute(windowId: windowId)
    }

    func recoverableMainWindowRoutes() -> [RecoverableMainWindowRoute] {
        windowRegistry.recoverableMainWindowRoutes()
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        windowRegistry.listMainWindowSummaries()
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        if let tabManager = windowRegistry.tabManagerFor(windowId: windowId) {
            return tabManager
        }
        // A registered context remains the windowId -> manager authority even
        // when its NSWindow is gone (mid-teardown) or absent (windowless test
        // contexts); otherwise window-scoped routing silently falls back to
        // another window's manager.
        return mainWindowContexts.values.first(where: { $0.windowId == windowId })?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        windowRegistry.windowId(for: tabManager)
    }

    func mainWindowContainingWorkspace(_ workspaceId: UUID) -> NSWindow? {
        windowRegistry.mainWindowContainingWorkspace(workspaceId)
    }

    func currentScriptableMainWindow() -> ScriptableMainWindowState? {
        windowRegistry.currentScriptableMainWindow()
    }

    func scriptableMainWindows() -> [ScriptableMainWindowState] {
        windowRegistry.scriptableMainWindows()
    }

    func scriptableMainWindow(windowId: UUID) -> ScriptableMainWindowState? {
        windowRegistry.scriptableMainWindow(windowId: windowId)
    }

    func scriptableMainWindowForTab(_ tabId: UUID) -> ScriptableMainWindowState? {
        windowRegistry.scriptableMainWindowForTab(tabId)
    }

    /// Returns the `TabManager` that owns `tabId`, if any.
    func tabManagerFor(tabId: UUID) -> TabManager? {
        windowRegistry.tabManagerFor(tabId: tabId)
    }
}
