import AppKit
import CmuxNextDaemon

extension WindowController {
    /// Shows top page `route` in the content area (TOP-SECTION-ITEMS-ARE-PAGES):
    /// the shown workspace parks and stays mounted, `state.workspaceID` stays,
    /// so selecting a workspace swaps it back in the same frame. One
    /// synchronous swap, like a workspace switch. False when no provider
    /// serves the route (the window then shows its workspace).
    @discardableResult
    func showTopPage(_ route: TopPageRoute) -> Bool {
        guard let view = topPages.view(for: route, in: self) else { return false }
        if root.content === view { return true }
        parkContentForPage()
        root.show(view)
        // Pages draw in the room theme (the window's own scope).
        ThemeLaunchLog.mark("show page=\(route.rawValue)")
        themeScope.show(nil)
        root.titlebar.title = topPages.title(for: route)
        services.windows.recordSaver.stateDidChange(state)
        services.cloudContextDidChange()
        return true
    }

    /// Shows the Home page in place of the store's home workspace while the
    /// Home item stands for it (its row is hidden then). False: show `workspace`.
    func showsHomePage(instead workspace: WorkspaceModel) -> Bool {
        guard workspace.kind == "home", SidebarBridge.hidesHome(services.sidebarLayout.document) else { return false }
        if state.workspaceID != workspace.id { state.workspaceID = workspace.id }
        if state.page != .home { state.page = .home }
        return showTopPage(.home)
    }

    /// The top page this window shows, if any.
    var shownTopPage: TopPageRoute? {
        guard let route = state.page, let view = topPages.views[route], root.content === view else { return nil }
        return route
    }
}
