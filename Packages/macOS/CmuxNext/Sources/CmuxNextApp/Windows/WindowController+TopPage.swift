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
        themeScope.show(nil)
        root.titlebar.title = topPages.title(for: route)
        services.windows.recordSaver.stateDidChange(state)
        services.cloudContextDidChange()
        services.locationTrail.pageHistoryDidChange()
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

    /// The content of the workspace this window names: the shown one, else
    /// the parked one under a top page (a tab opened behind the page lands
    /// there).
    var workspaceContent: WorkspaceContentController? {
        content ?? parked.last { $0.workspace.id == state.workspaceID }
    }

    /// Leaves the top page for the window's workspace at once
    /// (SIDEBAR-SELECTION-ONE-MODEL: one selection, so showing something in
    /// the workspace selects it). True when a page was left.
    @discardableResult
    func leaveTopPage() -> Bool {
        guard state.page != nil else { return false }
        state.page = nil
        services.windows.recordSaver.stateDidChange(state)
        showWorkspace(requested: state.workspaceID)
        return true
    }

    /// Leo (T3 Code ref, 2026-10-07): a full-page destination turns the sidebar's footer into
    /// Back, which returns the window to its workspace. Home is where you land, not a
    /// destination, so it keeps the footer.
    func followTopPageForBack() {
        sidebar.model.onBack = { [weak self] in self?.leaveTopPage() }
        root.onContentChange = { [weak self] in self?.syncSidebarBack() }
        // The window may have restored a page before this ran.
        syncSidebarBack()
    }

    private func syncSidebarBack() {
        let showsBack = shownTopPage.map { $0 != .home } ?? false
        if sidebar.model.showsBack != showsBack { sidebar.model.showsBack = showsBack }
    }

    /// The top page this window shows, if any.
    var shownTopPage: TopPageRoute? {
        guard let route = state.page, let view = topPages.views[route], root.content === view else { return nil }
        return route
    }
}
