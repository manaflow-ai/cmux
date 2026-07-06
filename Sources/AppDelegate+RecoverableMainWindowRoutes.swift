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
        windowRegistry.tabManagerFor(windowId: windowId)
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

    /// A single `tabId -> title` index across every registered window and the
    /// active manager, built once per render instead of an O(tabs) scan per row
    /// (#5794). Adapts main's `mainWindowContexts` read to the refactor's
    /// `registeredMainWindows`.
    func tabTitlesByTabId() -> [UUID: String] {
        var titles: [UUID: String] = [:]
        for context in registeredMainWindows {
            for tab in context.tabManager.tabs where titles[tab.id] == nil {
                titles[tab.id] = tab.title
            }
        }
        if let activeTabs = tabManager?.tabs {
            for tab in activeTabs where titles[tab.id] == nil {
                titles[tab.id] = tab.title
            }
        }
        return titles
    }
}
