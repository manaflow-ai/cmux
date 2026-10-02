import AppKit
import CmuxNextActions
import CmuxNextApps
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar
import Observation

// Sidebar sections (plans/cmux-next/sidebar-sections.md): every window
// draws `SidebarLayoutService.document`; built-in items run their registry
// action as the user; pinned workspaces select, and pinned tabs, pages
// and spaces open (SidebarBridge+PinnedItems); layout ops go to the
// service, which refuses them until the store serves `sidebar-layout-v1`.
extension SidebarBridge {
    /// The registry action each built-in runs.
    static let builtInActions: [SidebarBuiltIn: ActionID] = [
        .home: "home.show",
        .settings: "openSettings",
        .account: "accounts.show",
        .notifications: "showNotifications",
        .history: "history.show",
        .bookmarks: "bookmark.manager",
        .appStore: "appStore.show",
    ]

    func activateLayoutItem(_ id: LayoutItemID) {
        guard let item = model.layout.item(id) else { return }
        activate(item.ref)
    }

    /// Runs a sidebar item (sidebar-sections.md 2): pinned tabs, pages and
    /// spaces are in SidebarBridge+PinnedItems.
    func activate(_ ref: LayoutItemRef) {
        if let builtIn = ref.builtIn, let action = Self.builtInActions[builtIn] {
            _ = services.registry.perform(action, invocation: ActionInvocation(origin: .user))
            return
        }
        switch ref.kind {
        case LayoutItemRef.workspaceKind: handle(.select(SidebarWorkspaceID(ref.value)))
        case LayoutItemRef.tabKind: revealPinnedTab(ref.value)
        case LayoutItemRef.urlKind: openPinnedPage(ref.value)
        case LayoutItemRef.roomKind: switchToPinnedSpace(ref.value)
        default: break
        }
    }

    /// Keeps `model.itemInfo` current: a built-in whose action this build
    /// does not register draws dimmed.
    func observeSections() {
        let model = model
        let registry = services.registry
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        let service = services.sidebarLayout
        let apps = services.apps.registry
        sectionsObservation = Task { [weak self] in
            // The app registry is observed too: hiding or installing an app
            // changes its item at once.
            for await layout in Observations({ _ = apps.apps; return service.document }) {
                guard self != nil else { return }
                if model.layout != layout { model.layout = layout }
                let infos = Self.itemInfo(for: layout, registered: { registry.action(for: $0) != nil },
                                          app: { Self.appInfo($0, registry: apps) })
                if model.itemInfo != infos { model.itemInfo = infos }
            }
        }
    }

    /// Presentation of every built-in item in `layout`; `registered` says
    /// whether an action exists.
    static func itemInfo(for layout: SidebarLayoutDocument, registered: (ActionID) -> Bool,
                         app: (String) -> SidebarItemInfo = { SidebarItemInfo.fallback(for: .app($0)) }) -> [LayoutItemID: SidebarItemInfo] {
        var infos: [LayoutItemID: SidebarItemInfo] = [:]
        for section in layout.sections {
            for item in section.items {
                if item.ref.kind == LayoutItemRef.appKind {
                    infos[item.id] = app(item.ref.value)
                    continue
                }
                guard let builtIn = item.ref.builtIn else { continue }
                var info = builtIn.defaultInfo
                info.isMissing = !(builtInActions[builtIn].map(registered) ?? false)
                infos[item.id] = info
            }
        }
        return infos
    }

    /// How an app item draws: its name and symbol; hidden while the app is
    /// hidden or not active (D55); dimmed when the app is not installed.
    static func appInfo(_ id: String, registry: AppRegistry) -> SidebarItemInfo {
        guard let app = registry.app(id) else { return SidebarItemInfo.fallback(for: .app(id)) }
        let symbol = if case .symbol(let name)? = app.manifest.icon { name } else { "app" }
        return SidebarItemInfo(title: app.manifest.name.resolved(), symbol: symbol, isMissing: !app.isInstalled,
                               isHidden: app.isInstalled && !app.isVisible)
    }

    /// A layout change from this sidebar (a drag, an inline edit): sent to
    /// the layout owner; a refusal shows in the refusal HUD.
    /// The right-click menu of a layout item: Hide only on app items.
    func layoutItemMenu(_ id: LayoutItemID) -> NSMenu? {
        let isApp = model.layout.item(id)?.ref.kind == LayoutItemRef.appKind
        let menus = ContextMenuCatalog.shared
        let entries = isApp ? menus.entries(for: .sidebarItem) : menus.entries(for: .sidebarItem, removing: ["sidebar.item.hideApp"])
        return services.registry.makeContextMenu(for: .sidebarItem, target: ActionTargetRef(kind: .sidebarItem, id: id.rawValue),
                                                 entries: entries)
    }

    func applyLayoutOp(_ op: SidebarLayoutOp) {
        do { try services.sidebarLayout.send(op) } catch { services.registry.refuse(String(describing: error)) }
    }
}
