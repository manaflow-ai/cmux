import AppKit
import CmuxNextActions
import CmuxNextApps
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextIcons
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
        .account: "sidebar.profileMenu", // the profile control (amendment 2); Accounts stays `accounts.show`
        .notifications: "showNotifications",
        .history: "history.show",
        .bookmarks: "bookmark.manager",
        .appStore: "appStore.show",
        .newTerminal: "newSurface",
        .newBrowser: "openBrowser",
        .newAgentChat: "palette.newAgentChat",
        .customize: "appearance.customize",
        .searchChats: "agentPane.searchChats",
    ]

    /// Runs item `id` as a click does: a top-section item that stands for a
    /// page opens that page in this window (TOP-SECTION-ITEMS-ARE-PAGES).
    func activateLayoutItem(_ id: LayoutItemID, opensWorkspace: Bool = false) {
        guard let item = model.layout.item(id) else { return WhatsNewPage.activateClientItem(id, services: services, in: state) }
        if let region = model.layout.region(of: id), let route = TopPageRoute(item.ref, in: region),
           TopPages.show(route, services: services, in: state) != nil { return }
        activate(item.ref, opensWorkspace: opensWorkspace)
    }

    /// Runs a sidebar item (sidebar-sections.md 2); pinned tabs, pages, spaces: SidebarBridge+PinnedItems.
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
        sectionsObservation = Task { [weak self] in
            // The app registry is observed too: hiding or installing an app
            // changes its item at once.
            // So are the unread count (Notifications' dot) and the built-ins'
            // shortcuts (their tooltips, e.g. the footer gear's "Settings (⌘,)").
            // The selected item comes from the one selection (SidebarModel.selectedItem).
            for await (layout, unread, shortcuts, showChats) in Observations({ () -> (SidebarLayoutDocument, Int, [ActionID: String], Bool) in
                _ = apps.apps
                return (service.document, NotificationCenterService.unreadCount(store), Self.builtInShortcuts(registry),
                        DesignSettings.shared.sidebarSections.showChats)
            }) {
                guard let self else { return }
                let visibleLayout = layout.chatsLayout(enabled: showChats)
                if model.layout != visibleLayout { model.layout = visibleLayout }
                self.chatsMount.show(showChats, services: self.services)
                let infos = Self.itemInfo(for: visibleLayout, registered: { registry.action(for: $0) != nil },
                                          unread: unread,
                                          app: { Self.appInfo($0, registry: apps) }, shortcut: { shortcuts[$0] })
                if model.itemInfo != infos { model.itemInfo = infos }
                let suppressed = AppPresence(apps.apps).suppressed
                if model.suppressedApps != suppressed { model.suppressedApps = suppressed }
            }
        }
    }

    /// The shortcut of each built-in's action, as menus show it.
    static func builtInShortcuts(_ registry: ActionRegistry) -> [ActionID: String] {
        var shortcuts: [ActionID: String] = [:]
        for action in builtInActions.values {
            if let shortcut = registry.shortcutDisplay(for: action) { shortcuts[action] = shortcut }
        }
        return shortcuts
    }

    /// Presentation of every built-in item in `layout`; `registered` says
    /// whether an action exists. Notifications carries `unread`, and each
    /// built-in carries its action's `shortcut` for its tooltip. The update
    /// notice is the footer's pill, never an item control (SIDEBAR-FOOTER-MINIMAL).
    static func itemInfo(for layout: SidebarLayoutDocument, registered: (ActionID) -> Bool,
                         unread: Int = 0,
                         app: (String) -> SidebarItemInfo = { SidebarItemInfo.fallback(for: .app($0)) },
                         shortcut: (ActionID) -> String? = { _ in nil }) -> [LayoutItemID: SidebarItemInfo] {
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
                info.shortcut = builtInActions[builtIn].flatMap(shortcut)
                if builtIn == .notifications { info.badge = unread > 0 ? unread : nil }
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
        // A first-party app keeps its former built-in's icon and tile caption; no symbol draws the generic app.
        let firstParty = SidebarBuiltIn.firstParty(appID: id), icon = firstParty?.icon ?? (symbol == "app" ? IconName.appGeneric : nil)
        return SidebarItemInfo(title: app.manifest.name.resolved(), symbol: symbol, icon: icon, isMissing: !app.isInstalled,
                               isHidden: AppPresence([app]).suppressed.contains(id), caption: firstParty?.caption)
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
