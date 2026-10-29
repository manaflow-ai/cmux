import AppKit
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextWakeups

extension WindowController {
    /// Shows the requested workspace (or top page) whenever what it depends on changes. A service observation:
    /// it parks, discards and wakes workspaces for a hidden window too.
    func observeWorkspace() {
        guard !tornDown else { return }
        let machines = services.machines, cloud = services.cloud, windows = services.windows, state = state
        workspaceObservation = ServiceObservation(.visible, owner: "WindowController.showWorkspace", on: services.mainWork) {
            Self.readShowInputs(state, cloud: cloud, machines: machines, windows: windows)
        } apply: { [weak self] _ in
            self?.showWorkspace(requested: state.workspaceID)
            // A parked terminal (the classic migration's background workspaces) starts on its first show.
            if let id = state.workspaceID, let (workspace, daemon) = machines.workspace(id: id) { daemon.wakeParkedTabs(in: workspace) }
        }
    }

    /// Reads what `showWorkspace` depends on (the request, each machine's workspace list): O(machines), no id list.
    private static func readShowInputs(_ state: WindowState, cloud: CloudService, machines: MachineRegistry, windows: WindowManager) {
        _ = (state.workspaceID, state.page, state.machineID, cloud.hasLoadedMachines, multiViewEnabled, LayoutTunables.dockedWorkspaces.value)
        _ = creationKey(state, cloud, machines)
        _ = windows.registry.members(of: state.id)
        for daemon in machines.daemons { _ = (daemon.store.isLoaded, daemon.store.workspaces.count) }
    }

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
        // A page built again after a discard shows as the person left it.
        topPages.didShow(route)
        // Pages draw in the room theme (the window's own scope).
        themeScope.show(nil)
        root.titlebar.title = topPages.title(for: route)
        services.windows.recordSaver.stateDidChange(state)
        services.cloudContextDidChange()
        services.canvasContextDidChange()
        services.locationTrail.pageHistoryDidChange()
        return true
    }

    /// Shows the Home page in place of the store's home workspace while the
    /// Home item stands for it (its row is hidden then). False: show `workspace`.
    func showsHomePage(instead workspace: WorkspaceModel) -> Bool {
        guard services.home.dock.isClassic, workspace.kind == "home", SidebarBridge.hidesHome(services.sidebarLayout.document) else { return false }
        if state.workspaceID != workspace.id { state.workspaceID = workspace.id }
        if state.page != .home { state.page = .home }
        return showTopPage(.home)
    }

    /// The content of the workspace this window names: the shown one, else
    /// the parked one under a top page (a tab opened behind the page lands
    /// there).
    var workspaceContent: WorkspaceContentController? {
        content ?? state.workspaceID.flatMap { parked[$0] }
    }

    /// Whether a page tab that a focused show opens here would be seen: the
    /// window shows (or can leave its top page for) a workspace with a pane,
    /// and Home does not stand for that workspace. A tab opened while Home
    /// stands for the home workspace lands in that hidden workspace and
    /// shows nothing (cx-cmge7), so such a show uses a top page instead.
    var holdsVisiblePageTab: Bool {
        guard let workspace = workspaceContent, !workspace.modelPanes.isEmpty else { return false }
        return !(services.home.dock.isClassic && workspace.workspace.kind == "home" && SidebarBridge.hidesHome(services.sidebarLayout.document))
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

    /// Every content swap, a top page or a workspace: the titlebar's Back and
    /// Forward re-read the shown page's history. The sidebar never shows Back
    /// (Lawrence 2026-10-09); Go Back leaves a page for its workspace. The
    /// top pages hear which page is hidden from now on, and when a page a paint
    /// hold kept on screen leaves the window (their discard deadlines).
    func followContentChanges() {
        root.onContentChange = { [weak self] in
            guard let self else { return }
            services.locationTrail.pageHistoryDidChange()
            topPages.contentDidChange(shown: root.content)
        }
        root.onContentWithdrawn = { [weak self] in self?.topPages.contentDidLeaveWindow() }
    }

    /// The top page this window shows, if any.
    var shownTopPage: TopPageRoute? {
        guard let route = state.page, let view = topPages.views[route], root.content === view else { return nil }
        return route
    }
}
