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
    /// (cx-lu8f): selected in place of the workspace under it.
    static func selectedItem(page: TopPageRoute?, workspace: String?, creationRow: String? = nil, layout: SidebarLayoutDocument,
                             room: String? = nil, refs: WorkspaceLayoutRefs? = nil) -> SidebarItem? {
        if let page {
            let item = layout.sections.filter { $0.region == .top }.flatMap(\.items).first { TopPageRoute.route(for: $0.ref) == page }
            return item.map { .topItem($0.id) }
        }
        if let creationRow { return .workspace(WorkspaceID(creationRow)) }
        guard let workspace else { return nil }
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

    /// Cmd-Ctrl-] (+1) / Cmd-Ctrl-[ (-1) in the active window.
    static func step(by offset: Int, _ services: AppServices) {
        guard let window = services.windows.active else { return }
        let model = window.sidebar.model
        // From the window state (the truth), not the sidebar's mirror of it, which may lag a turn.
        let current = selectedItem(page: window.state.page, workspace: window.state.workspaceID,
                                   creationRow: window.state.cloudCreation.flatMap { services.cloud.creations.creation($0)?.rowID }, layout: model.layout,
                                   room: window.state.profileID.rawValue, refs: WorkspaceLayoutRefs(machines: services.machines))
        guard let item = model.itemOrder.step(from: current, by: offset, settings(services)) else { return }
        activate(item, in: window, services)
    }

    /// Selects `item` as a click does: a top item runs (its page opens), a
    /// workspace shows, a collapsed group shows its first workspace.
    static func activate(_ item: SidebarItem, in window: WindowController, _ services: AppServices) {
        switch item {
        case .topItem(let id):
            window.sidebar.activateLayoutItem(id)
        case .workspace(let id):
            if showCreation(row: id.rawValue, in: window.state, services) { return }
            services.windows.show(workspaceID: id.rawValue, in: window.state)
        case .group(let id):
            guard let first = window.sidebar.model.group(id)?.workspaces.first else { return }
            services.windows.show(workspaceID: first.id.rawValue, in: window.state)
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

    /// The four `sidebar.*` navigation settings from cmux.json.
    static func settings(_ services: AppServices) -> SidebarNavigationSettings {
        services.settings?.snapshot.sidebarSections.navigation ?? .defaults
    }
}
