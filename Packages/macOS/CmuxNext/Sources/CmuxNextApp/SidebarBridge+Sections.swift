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
        .newWorkspace: "newTab",
        // The combined import entry opens onboarding, whose role step starts
        // both the classic-session and agent-chat scans.
        .importSync: "importAndSync.show",
        .customize: "appearance.customize",
    ]

    /// Runs item `id` as a click does: a top-section item that stands for a
    /// page opens that page in this window (TOP-SECTION-ITEMS-ARE-PAGES).
    func activateLayoutItem(_ id: LayoutItemID, opensWorkspace: Bool = false) {
        guard let item = model.layout.item(id) else { return }
        if let region = model.layout.region(of: id), let route = TopPageRoute(item.ref, in: region),
           TopPages.show(route, services: services, in: state) != nil { return }
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
            let (action, arguments) = Self.appActivation(ref.value, registered: { services.registry.action(for: $0) != nil })
            _ = services.registry.perform(action, invocation: ActionInvocation(arguments: arguments, origin: .user))
        default: break
        }
    }

    /// What an app item's click runs (R63/R64): `cmux.apps.open {app}` (it
    /// opens the app's screen or page as the manifest says) once it is
    /// registered. INTERIM until then: Home and the App Store keep their
    /// show actions, every other app opens its page (`app.open`).
    static func appActivation(_ app: String, registered: (ActionID) -> Bool) -> (ActionID, [String: ActionValue]) {
        if registered("cmux.apps.open") { return ("cmux.apps.open", ["app": .string(app)]) }
        if let action = interimAppActions[app], registered(action) { return (action, [:]) }
        return ("app.open", ["app": .string(app)])
    }

    private static let interimAppActions: [String: ActionID] = ["cmux/home": "home.show", "cmux/app-store": "appStore.show"]

    /// Keeps `model.itemInfo` current: a built-in whose action this build
    /// does not register draws dimmed.
    func observeSections() {
        let model = model
        let registry = services.registry
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        let service = services.sidebarLayout
        let apps = services.apps.registry
        let store = services.machines.local.store
        let window = state
        let updater = services.updater
        sectionsObservation = Task { [weak self] in
            // The app registry is observed too: hiding or installing an app
            // changes its item at once.
            // So are the shown top page (its item is active), the unread
            // count (Notifications' dot), and an available update (the
            // badge on Settings).
            for await (layout, shownPage, unread, update) in Observations({ () -> (SidebarLayoutDocument, TopPageRoute?, Int, String?) in
                _ = apps.apps
                return (service.document, window?.page, NotificationCenterService.unreadCount(store), updater.settingsBadgeTitle)
            }) {
                guard self != nil else { return }
                if model.layout != layout { model.layout = layout }
                let infos = Self.itemInfo(for: layout, registered: { registry.action(for: $0) != nil },
                                          shownPage: shownPage, unread: unread,
                                          app: { Self.appInfo($0, registry: apps) }, updateBadge: update)
                if model.itemInfo != infos { model.itemInfo = infos }
                let suppressed = AppPresence(apps.apps).suppressed
                if model.suppressedApps != suppressed { model.suppressedApps = suppressed }
            }
        }
    }

    /// Presentation of every built-in item in `layout`; `registered` says
    /// whether an action exists. The item of the shown top page is active, and
    /// Notifications carries `unread`. Settings carries the update badge
    /// while `updateBadge` is set, labelled with it (the window rail's update
    /// circle is gone, R52; the update card is gone, Lawrence 2026-10-05).
    static func itemInfo(for layout: SidebarLayoutDocument, registered: (ActionID) -> Bool,
                         shownPage: TopPageRoute? = nil, unread: Int = 0,
                         app: (String) -> SidebarItemInfo = { SidebarItemInfo.fallback(for: .app($0)) },
                         updateBadge: String? = nil) -> [LayoutItemID: SidebarItemInfo] {
        var infos: [LayoutItemID: SidebarItemInfo] = [:]
        for section in layout.sections {
            for item in section.items {
                if item.ref.kind == LayoutItemRef.appKind {
                    var info = app(item.ref.value)
                    info.isActive = shownPage != nil && TopPageRoute.route(for: item.ref) == shownPage
                    infos[item.id] = info
                    continue
                }
                guard let builtIn = item.ref.builtIn else { continue }
                var info = builtIn.defaultInfo
                info.isMissing = !(builtInActions[builtIn].map(registered) ?? false)
                switch builtIn {
                case .home, .appStore, .settings: info.isActive = shownPage != nil && TopPageRoute.route(for: item.ref) == shownPage
                case .notifications: info.badge = unread > 0 ? unread : nil
                case .settings: info.accessory = updateBadge.map { .update(title: $0) }
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
        // A first-party app keeps its former built-in's short tile caption.
        let caption = SidebarLayoutDocument.firstPartyApps.first { $0.value == id }?.key.caption
        return SidebarItemInfo(title: app.manifest.name.resolved(), symbol: symbol, isMissing: !app.isInstalled,
                               isHidden: AppPresence([app]).suppressed.contains(id), caption: caption)
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
