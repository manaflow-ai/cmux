import AppKit

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
        themeScope.show(nil)
        root.titlebar.title = topPages.title(for: route)
        services.windows.recordSaver.stateDidChange(state)
        services.cloudContextDidChange()
        return true
    }

    /// The top page this window shows, if any.
    var shownTopPage: TopPageRoute? {
        guard let route = state.page, let view = topPages.views[route], root.content === view else { return nil }
        return route
    }
}
