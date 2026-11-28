import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

extension AppServices {
    /// The workspace that holds tab `id`, on any machine.
    func workspaceID(ofTab id: String) -> String? {
        for (workspace, _) in machines.allWorkspaces
        where workspace.screens.contains(where: { $0.panes.contains { $0.tabs.contains { $0.id == id } } }) {
            return workspace.id
        }
        return nil
    }

    /// The workspace that holds tab group `group`.
    func workspaceID(ofTabGroup group: TabGroupID) -> String? {
        for (workspace, _) in machines.allWorkspaces
        where workspace.screens.contains(where: { $0.panes.contains { $0.tabGroups.contains { $0.id == group } } }) {
            return workspace.id
        }
        return nil
    }

    /// The workspace that holds `pane`.
    func workspaceID(of pane: PaneModel) -> String? {
        daemon(for: pane).store.workspace(containing: pane.handle)?.id
    }

    /// True when moving `tab` into `pane` would cross between an incognito
    /// window and a normal one (user decision 2026-09-30: never).
    func crossesIncognito(_ tab: TabModel, to pane: PaneModel) -> Bool {
        windows.crossesIncognito(from: workspaceID(ofTab: tab.id), to: workspaceID(of: pane))
    }

    /// The active window when it is a normal one, else the most recent
    /// normal window: where a normal page's request without a window goes.
    func normalWindowForPageRequest() -> WindowController? {
        if let active = windows.active, !windows.isIncognito(window: active.state.id) { return active }
        let value = windows.registry.value
        return value.mostRecentOpen().flatMap { windows.controller(for: $0) }
    }

    /// An incognito request from a page ("Open Link in Incognito Window",
    /// New Incognito Window): a new tab in the source page's
    /// window when that is incognito, else a new incognito window.
    func openOffTheRecord(_ url: URL?, source: (any BrowserTab)?) {
        if let source, let key = cache.key(of: source), let (_, pane) = locateTab(key),
           let workspace = workspaceID(of: pane), windows.isIncognito(workspace: workspace),
           let controller = paneController(for: pane) {
            controller.newBrowserTab(url: url, background: false)
            return
        }
        windows.newIncognitoWindow(url: url)
    }
}
