import CmuxNextDesign
import CmuxNextSidebar

/// The one sidebar selection and walk (SIDEBAR-SELECTION-ONE-MODEL,
/// SIDEBAR-NUMBERING-AND-STEPPING): the window state (page + workspace)
/// gives the selected `SidebarItem`; Cmd-1…9 and Cmd-Ctrl-[ / ] walk the
/// model's `itemOrder` and select the item as a click does.
@MainActor
enum SidebarNavigation {
    /// The selection the window state means: the top item of the shown page
    /// (the first item whose route it is), else the shown workspace: its
    /// tile or top row when the top region shows it in `room` (the list then
    /// leaves its row out), else its row.
    /// `creationRow` is the row of the Cloud creation the window shows
    /// (cx-lu8f): selected in place of the workspace under it. `home` is the
    /// docked Home's workspace (`HomeService.dockedHomeID`): the Home item
    /// stands for it (cx-ebm.59.5), and the Channels entry while `channels`
    /// (its dock shows Channels, cx-frn2y).
    static func selectedItem(page: TopPageRoute?, workspace: String?, creationRow: String? = nil, layout: SidebarLayoutDocument,
                             room: String? = nil, refs: WorkspaceLayoutRefs? = nil, home: String? = nil, channels: Bool = false) -> SidebarItem? {
        let topItem = { (route: TopPageRoute) in
            layout.sections.filter { $0.region == .top }.flatMap(\.items).first { TopPageRoute.route(for: $0.ref) == route }
        }
        if let page { return topItem(page).map { .topItem($0.id) } }
        if let creationRow { return .workspace(WorkspaceID(creationRow)) }
        guard let workspace else { return nil }
        if workspace == home, channels { return .topItem(SidebarTransientItem.channelsID) }
        if workspace == home, let item = topItem(.home) { return .topItem(item.id) }
        if let ref = refs?.ref(forWorkspace: workspace), let item = layout.topItem(for: ref, room: room) { return .topItem(item.id) }
        return .workspace(WorkspaceID(workspace))
    }

    /// Cmd-`number` in the active window.
    static func select(number: Int, _ services: AppServices) {
        guard let window = services.windows.active else { return }
        let model = window.sidebar.model
        guard let item = model.itemOrder.pick(number, settings(services)) else { return }
        activate(item, in: window, services)
    }

    /// Cmd-Ctrl-] (+1) / Cmd-Ctrl-[ (-1) in the active window; `scope` is the binding's (`stepping(_:scope:)`).
    static func step(by offset: Int, scope: String? = nil, _ services: AppServices) {
        guard let window = services.windows.active else { return }
        let model = window.sidebar.model
        let walk = stepping(settings(services), scope: scope)
        guard let item = model.itemOrder.step(from: current(in: window, services), by: offset, walk) else { return }
        activate(item, in: window, services)
    }

    /// The window's selection, from the window state (the truth), not the sidebar's mirror of it, which may lag a turn.
    static func current(in window: WindowController, _ services: AppServices) -> SidebarItem? {
        selectedItem(page: window.state.page, workspace: window.state.workspaceID,
                     creationRow: window.state.cloudCreation.flatMap { services.cloud.creations.creation($0)?.rowID }, layout: window.sidebar.model.layout,
                     room: window.state.profileID.rawValue, refs: WorkspaceLayoutRefs(machines: services.machines),
                     home: services.home.dockedHomeID, channels: services.home.dockShowsChannels)
    }

    /// Selects `item` as a click does: a top item runs (its page opens), a
    /// workspace shows, a collapsed group shows its first workspace.
    ///
    /// Pressed again on the item the window already selected (Cmd-1 twice,
    /// Lawrence 2026-10-19: "the second time nothing is highlighted"), it runs
    /// nothing: the selection and its highlight stay as they are, and the
    /// sidebar scrolls the item into view (no selection change reaches it).
    static func activate(_ item: SidebarItem, in window: WindowController, _ services: AppServices) {
        if window.sidebar.model.itemOrder.stop(for: current(in: window, services)) == item {
            window.sidebar.container.sidebarView.revealSelection()
            return
        }
        switch item {
        case .topItem(let id):
            window.sidebar.activateLayoutItem(id)
        case .workspace(let id):
            if showCreation(row: id.rawValue, in: window.state, services) { return }
            services.windows.show(workspaceID: id.rawValue, in: window.state, from: .thisWindow)
        case .group(let id):
            guard let first = window.sidebar.model.group(id)?.workspaces.first else { return }
            services.windows.show(workspaceID: first.id.rawValue, in: window.state, from: .thisWindow)
        }
    }

    /// A Cloud creation's row (cx-lu8f) is no workspace: selecting it shows
    /// the creation's progress in the window. False for any other row.
    static func showCreation(row: String, in state: WindowState, _ services: AppServices) -> Bool {
        guard let creation = services.cloud.creations.creation(row: row) else { return false }
        state.page = nil
        state.cloudCreation = creation.id
        return true
    }

    /// The `scope` argument of workspaces as tabs' Cmd-Shift-] / [ (`KeyBindingDefaults.workspacesAsTabs`).
    static let workspacesScope = "workspaces"

    /// The walk of a step whose binding names `scope`. Workspaces as tabs' keys visit only
    /// workspaces and collapsed groups and always wrap (Leo: "wrapping, across groups"), whatever
    /// `sidebar.stepping` says, so they never land on Home and lose their keys there; Ctrl-Cmd-] / [
    /// (no scope) keep the settings.
    static func stepping(_ settings: SidebarNavigationSettings, scope: String?) -> SidebarNavigationSettings {
        guard scope == workspacesScope else { return settings }
        var walk = settings
        (walk.stepping, walk.steppingWraps) = (.workspacesOnly, true)
        return walk
    }

    /// The four `sidebar.*` navigation settings from cmux.json.
    static func settings(_ services: AppServices) -> SidebarNavigationSettings {
        services.settings?.snapshot.sidebarSections.navigation ?? .defaults
    }
}
