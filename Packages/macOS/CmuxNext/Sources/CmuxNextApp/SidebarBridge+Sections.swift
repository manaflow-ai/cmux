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
        .newTerminal: "newSurface",
        .newBrowser: "openBrowser",
        .newAgentChat: "palette.newAgentChat",
        .customize: "appearance.customize",
    ]

    func activateLayoutItem(_ id: LayoutItemID, opensWorkspace: Bool = false) {
        guard let item = model.layout.item(id) else { return }
        activate(item.ref, opensWorkspace: opensWorkspace)
    }

    /// Runs a sidebar item (sidebar-sections.md 2): pinned tabs, pages and
    /// spaces are in SidebarBridge+PinnedItems.
    func activate(_ ref: LayoutItemRef, opensWorkspace: Bool = false) {
        if let builtIn = ref.builtIn, let action = Self.builtInActions[builtIn] {
            var invocation = ActionInvocation(origin: .user)
            if opensWorkspace, builtIn == .newTerminal { invocation.arguments["toggleWorkspace"] = .bool(true) }
            _ = services.registry.perform(action, invocation: invocation)
            return
        }
        switch ref.kind {
        case LayoutItemRef.workspaceKind: handle(.select(SidebarWorkspaceID(ref.value)))
        case LayoutItemRef.tabKind: revealPinnedTab(ref.value)
        case LayoutItemRef.urlKind: openPinnedPage(ref.value)
        case LayoutItemRef.roomKind: switchToPinnedSpace(ref.value)
        case LayoutItemRef.appKind:
            // An app's label item opens its page as a tab (CodeRouter below the App Store).
            _ = services.registry.perform("app.open", invocation: ActionInvocation(arguments: ["app": .string(ref.value)], origin: .user))
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
        let home = services.home, store = services.machines.local.store
        let window = state
        sectionsObservation = Task { [weak self] in
            // The app registry is observed too: hiding or installing an app
            // changes its item at once.
            // So are the shown workspace (Home's selected tile) and the
            // unread count (Notifications' dot).
            for await (layout, homeShown, unread) in Observations({ () -> (SidebarLayoutDocument, Bool, Int) in
                _ = apps.apps
                let shown = window?.workspaceID
                return (service.document, shown != nil && shown == home.homeWorkspace?.id, NotificationCenterService.unreadCount(store))
            }) {
                guard self != nil else { return }
                if model.layout != layout { model.layout = layout }
                let infos = Self.itemInfo(for: layout, registered: { registry.action(for: $0) != nil },
                                          homeShown: homeShown, unread: unread,
                                          app: { Self.appInfo($0, registry: apps) })
                if model.itemInfo != infos { model.itemInfo = infos }
                let suppressed = AppPresence(apps.apps).suppressed
                if model.suppressedApps != suppressed { model.suppressedApps = suppressed }
            }
        }
    }

    /// Presentation of every built-in item in `layout`; `registered` says
    /// whether an action exists. Home is active while `homeShown`, and
    /// Notifications carries `unread`.
    static func itemInfo(for layout: SidebarLayoutDocument, registered: (ActionID) -> Bool,
                         homeShown: Bool = false, unread: Int = 0,
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
                switch builtIn {
                case .home: info.isActive = homeShown
                case .notifications: info.badge = unread > 0 ? unread : nil
                default: break
                }
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
                               isHidden: AppPresence([app]).suppressed.contains(id))
    }

    /// A layout change from this sidebar (a drag, an inline edit): sent to
    /// the layout owner; a refusal shows in the refusal HUD.
    /// The right-click menu of a section: Hide only on an app section.
    func layoutSectionMenu(_ id: LayoutSectionID) -> NSMenu? {
        let isApp = model.layout.section(id)?.owningAppID != nil
        let menus = ContextMenuCatalog.shared
        let entries = isApp ? menus.entries(for: .sidebarSection) : menus.entries(for: .sidebarSection, removing: ["sidebar.item.hideApp"])
        return services.registry.makeContextMenu(for: .sidebarSection, target: ActionTargetRef(kind: .sidebarSection, id: id.rawValue),
                                                 entries: entries)
    }

    /// The right-click menu of a layout item: Hide only on app items.
    func layoutItemMenu(_ id: LayoutItemID) -> NSMenu? {
        let isApp = model.layout.item(id)?.owningAppID != nil
        let menus = ContextMenuCatalog.shared
        let entries = isApp ? menus.entries(for: .sidebarItem) : menus.entries(for: .sidebarItem, removing: ["sidebar.item.hideApp"])
        return services.registry.makeContextMenu(for: .sidebarItem, target: ActionTargetRef(kind: .sidebarItem, id: id.rawValue),
                                                 entries: entries)
    }

    func applyLayoutOp(_ op: SidebarLayoutOp) {
        do { try services.sidebarLayout.send(op) } catch { services.registry.refuse(String(describing: error)) }
    }
}
