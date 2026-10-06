import CmuxNextDesign
import CmuxNextSidebar

/// The one sidebar selection and walk (SIDEBAR-SELECTION-ONE-MODEL,
/// SIDEBAR-NUMBERING-AND-STEPPING): the window state (page + workspace)
/// gives the selected `SidebarItem`; Cmd-1…9 and Cmd-Ctrl-[ / ] walk the
/// model's `itemOrder` and select the item as a click does.
@MainActor
enum SidebarNavigation {
    /// The selection the window state means: the top item of the shown page
    /// (the first item whose route it is), else the shown workspace.
    static func selectedItem(page: TopPageRoute?, workspace: String?, layout: SidebarLayoutDocument) -> SidebarItem? {
        if let page {
            let item = layout.sections.filter { $0.region == .top }.flatMap(\.items).first { TopPageRoute.route(for: $0.ref) == page }
            return item.map { .topItem($0.id) }
        }
        return workspace.map { .workspace(WorkspaceID($0)) }
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
        guard let item = model.itemOrder.step(from: model.selectedItem, by: offset, settings(services)) else { return }
        activate(item, in: window, services)
    }

    /// Selects `item` as a click does: a top item runs (its page opens), a
    /// workspace shows, a collapsed group shows its first workspace.
    static func activate(_ item: SidebarItem, in window: WindowController, _ services: AppServices) {
        switch item {
        case .topItem(let id):
            window.sidebar.activateLayoutItem(id)
        case .workspace(let id):
            services.windows.show(workspaceID: id.rawValue, in: window.state)
        case .group(let id):
            guard let first = window.sidebar.model.group(id)?.workspaces.first else { return }
            services.windows.show(workspaceID: first.id.rawValue, in: window.state)
        }
    }

    /// The four `sidebar.*` navigation settings from cmux.json.
    static func settings(_ services: AppServices) -> SidebarNavigationSettings {
        services.settings?.snapshot.sidebarSections.navigation ?? .defaults
    }
}
