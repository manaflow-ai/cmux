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
        case LayoutItemRef.workspaceKind:
            if let id = WorkspaceLayoutRefs(machines: services.machines).activationID(for: ref) { handle(.select(SidebarWorkspaceID(id))) }
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
        let refs = WorkspaceLayoutRefs(machines: services.machines)
        sectionsObservation = Task { [weak self] in
            // Also observed: the app registry, the unread count, the built-ins' shortcuts (tooltips), the Chats
            // setting and the workspaces tiles and top rows name. The selected item comes from the one selection.
            for await (layout, unread, shortcuts, showChats, workspaces) in Observations({
                () -> (SidebarLayoutDocument, Int, [ActionID: String], Bool, [LayoutItemRef: SidebarItemInfo]) in
                _ = apps.apps
                return (service.document, NotificationCenterService.unreadCount(store), Self.builtInShortcuts(registry),
                        DesignSettings.shared.sidebarSections.showChats, SidebarWorkspaceItems.workspaceInfos(service.document, refs: refs))
            }) {
                guard let self else { return }
                // `model.layout` is written with the rows it projects (SidebarBridge.show).
                let visibleLayout = layout.chatsLayout(enabled: showChats)
                self.chatsMount.show(showChats, services: self.services)
                let infos = Self.itemInfo(for: visibleLayout, registered: { registry.action(for: $0) != nil },
                                          unread: unread,
                                          app: { SidebarAppItemInfo.info($0, registry: apps) }, shortcut: { shortcuts[$0] },
                                          workspace: { workspaces[$0] })
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

    /// Presentation of every built-in, app and workspace item in `layout` (a closed workspace dimmed); `registered` says
    /// whether an action exists. Notifications carries `unread`, and each
    /// built-in carries its action's `shortcut` for its tooltip. The update
    /// notice is the footer's pill, never an item control (SIDEBAR-FOOTER-MINIMAL).
    static func itemInfo(for layout: SidebarLayoutDocument, registered: (ActionID) -> Bool,
                         unread: Int = 0,
                         app: (String) -> SidebarItemInfo = { SidebarItemInfo.fallback(for: .app($0)) },
                         shortcut: (ActionID) -> String? = { _ in nil },
                         workspace: (LayoutItemRef) -> SidebarItemInfo? = { _ in nil }) -> [LayoutItemID: SidebarItemInfo] {
        var infos: [LayoutItemID: SidebarItemInfo] = [:]
        for section in layout.sections {
            for item in section.items {
                if item.ref.kind == LayoutItemRef.workspaceKind { infos[item.id] = workspace(item.ref) ?? .fallback(for: item); continue }
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

    /// A layout change from this sidebar (a drag, an inline edit): sent to
    /// the layout owner; a refusal shows in the refusal HUD.
    /// The right-click menu of a section: Hide only on an app section, Hide
    /// Section only on Recents (`SidebarHiddenSections`).
    func layoutSectionMenu(_ id: LayoutSectionID) -> NSMenu? {
        let isApp = model.layout.section(id)?.owningAppID != nil
        let entries = ContextMenuCatalog.shared.entries(for: .sidebarSection, removing: SidebarHiddenSections.headerMenuRemovals(id, isApp: isApp))
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
        PinCommands(context: AppActionContext(services: services)).userBandEdit(op)
    }
}
