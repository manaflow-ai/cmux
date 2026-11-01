import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextApps
import CmuxNextBridge
import CmuxNextCompat
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
        .chief: ChiefSidebar.openAction,
        .automations: "automations.show",
    ]

    /// Runs item `id` as a click does: a top-section item that stands for a
    /// page opens that page in this window (TOP-SECTION-ITEMS-ARE-PAGES).
    func activateLayoutItem(_ id: LayoutItemID, opensWorkspace: Bool = false) {
        guard let item = model.layout.item(id) ?? model.listedItem(id) else { return WhatsNewPage.activateClientItem(id, services: services, in: state) }
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
        // Another client's group fold (the sidebar document's fold-only batches) folds this window's rows. After the
        // `sidebarLayout` read, which starts this app's document.
        if let doc = services.sidebarDoc.store { rows.edits.followFolds(of: doc) }
        let apps = services.apps.client
        let store = services.machines.local.store
        let settings = services.settings
        let refs = WorkspaceLayoutRefs(machines: services.machines)
        // The default Chief's worn upload is the Chief item's picture; none keeps the plain glyph (no pet picture, Lawrence 2026-10-31).
        let chiefPicture = { [weak services] in services?.wornUpload(of: nil)?.still }
        let uploads = services.chiefAvatarUploads
        let home = services.home
        sectionsObservation = Task { [weak self] in
            // Also observed: the apps client (installs, hides), the unread count, Home's unread conversations, the built-ins' shortcuts (tooltips) and
            // the workspaces tiles and top rows name. The selected item comes from the one selection.
            for await (layout, unread, homeUnread, shortcuts, workspaces, picture, previewFeatures) in ObservationStream({
                () -> (SidebarLayoutDocument, Int, Int, [ActionID: String], [LayoutItemRef: SidebarItemInfo], URL?, Bool) in
                _ = (apps.apps, ChiefSidebar.shared.status)
                return (service.document, NotificationCenterService.unreadCount(store), home.unreadConversations.count,
                        Self.builtInShortcuts(registry), SidebarWorkspaceItems.workspaceInfos(service.document, refs: refs), chiefPicture(), settings?.snapshot.previewFeatures == true)
            }) {
                // The window closed: the bridge is gone, stop observing.
                guard self != nil else { return }
                // `model.layout` is written with the rows it projects (SidebarBridge.show).
                let visibleLayout = SidebarRows.visibleLayout(layout, showAppStore: previewFeatures)
                let infos = Self.itemInfo(for: visibleLayout, registered: { registry.action(for: $0) != nil },
                                          unread: unread, homeUnread: homeUnread,
                                          app: { SidebarAppItemInfo.info($0, client: apps) }, shortcut: { shortcuts[$0] },
                                          workspace: { workspaces[$0] }, chiefPicture: picture,
                                          chiefImage: picture.flatMap(uploads.image(at:)))
                if model.itemInfo != infos { model.itemInfo = infos }
                if model.newWorkspaceShortcut != shortcuts["newTab"] { model.newWorkspaceShortcut = shortcuts["newTab"] }
                let suppressed = AppPresence(apps.apps).suppressed
                if model.suppressedApps != suppressed { model.suppressedApps = suppressed }
            }
        }
    }

    /// Built-in tooltips and the empty-workspace hint use the same shortcut text as menus.
    static func builtInShortcuts(_ registry: ActionRegistry) -> [ActionID: String] {
        var shortcuts: [ActionID: String] = [:]
        for action in Array(builtInActions.values) + ["newTab"] {
            if let shortcut = registry.shortcutDisplay(for: action) { shortcuts[action] = shortcut }
        }
        return shortcuts
    }

    /// Presentation of every built-in, app and workspace item in `layout` (a closed workspace dimmed); `registered` says
    /// whether an action exists. Notifications carries `unread`, Home (built-in or app) a dot for `homeUnread` (its
    /// unread conversations, ``HomeService/unreadConversations``), the Chief its status (`ChiefSidebar`) and the
    /// picture `chiefPicture` (its worn upload, first frame `chiefImage` already decoded, or its character's), else
    /// that of the chosen pet character `chiefMascot` (`home.chiefPetMascot`), and each
    /// built-in carries its action's `shortcut` for its tooltip. The update
    /// notice is the footer's pill, never an item control (SIDEBAR-FOOTER-MINIMAL).
    static func itemInfo(for layout: SidebarLayoutDocument, registered: (ActionID) -> Bool,
                         unread: Int = 0,
                         homeUnread: Int = 0,
                         app: (String) -> SidebarItemInfo = { SidebarItemInfo.fallback(for: .app($0)) },
                         shortcut: (ActionID) -> String? = { _ in nil },
                         workspace: (LayoutItemRef) -> SidebarItemInfo? = { _ in nil },
                         chiefMascot: String? = nil, chiefPicture: URL? = nil,
                         chiefImage: CGImage? = nil) -> [LayoutItemID: SidebarItemInfo] {
        var infos: [LayoutItemID: SidebarItemInfo] = [:]
        for section in layout.sections {
            for item in section.items {
                if item.ref.kind == LayoutItemRef.workspaceKind { infos[item.id] = workspace(item.ref) ?? closedWorkspaceInfo(item); continue }
                if item.ref.kind == LayoutItemRef.appKind {
                    var info = app(item.ref.value)
                    if SidebarBuiltIn.firstParty(appID: item.ref.value) == .home { Self.markHomeUnread(&info, homeUnread) }
                    infos[item.id] = info
                    continue
                }
                guard let builtIn = item.ref.builtIn else { continue }
                var info = builtIn.defaultInfo
                info.isMissing = !(builtInActions[builtIn].map(registered) ?? false)
                info.shortcut = builtInActions[builtIn].flatMap(shortcut)
                if builtIn == .notifications { info.badge = unread > 0 ? unread : nil } else if builtIn == .home {
                    Self.markHomeUnread(&info, homeUnread)
                } else if builtIn == .chief {
                    ChiefSidebar.shared.decorate(&info)
                    info.favicon = chiefPicture.flatMap { ChiefSidebarPicture.favicon(mascot: chiefMascot, picture: $0, image: chiefImage) }
                }
                infos[item.id] = info
            }
        }
        return infos
    }

    /// Home's unread indicator: the blue unread dot of a workspace row while any Home conversation is
    /// unread, never a count (Lawrence 2026-10-23: "home unread indicator should just be blue dot instead").
    static func markHomeUnread(_ info: inout SidebarItemInfo, _ homeUnread: Int) {
        info.badge = nil
        info.unreadDot = homeUnread > 0
    }

    /// A workspace item no open workspace answers: dimmed under its stored
    /// name, or hidden when it has none. Without a name it would be an
    /// anonymous workspace glyph whose click does nothing (a pin from an old
    /// daemon session; Lawrence 2026-10-21 "what are these 2 weird things").
    /// The layout keeps it, so it draws again when its workspace comes back.
    static func closedWorkspaceInfo(_ item: LayoutItem) -> SidebarItemInfo {
        var info = SidebarItemInfo.fallback(for: item)
        if item.label == nil { info.isHidden = true }
        return info
    }

    /// A layout change from this sidebar (a drag, an inline edit): sent to
    /// the layout owner; a refusal shows in the refusal HUD.
    /// The right-click menu of a section: Hide only on an app section, Hide
    /// Section only on Recents (`SidebarHiddenSections`).
    func layoutSectionMenu(_ id: LayoutSectionID) -> NSMenu? {
        let isApp = model.layout.section(id)?.owningAppID != nil
        let entries = services.registry.contextMenuEntries(for: .sidebarSection, removing: SidebarHiddenSections.headerMenuRemovals(id, isApp: isApp))
        return services.registry.makeContextMenu(for: .sidebarSection, target: ActionTargetRef(kind: .sidebarSection, id: id.rawValue),
                                                 entries: entries, customize: true)
    }

    /// The open workspace a pinned workspace's tile names, or nil (another item, a closed or
    /// another device's workspace, or a workspace tile in a section other than Pinned, which keeps
    /// its item menu: Remove from Section, Remove from Sidebar).
    func pinnedWorkspaceID(ofItem id: LayoutItemID) -> SidebarWorkspaceID? {
        guard let ref = (model.layout.item(id) ?? model.listedItem(id))?.ref,
              let (workspace, _) = WorkspaceLayoutRefs(machines: services.machines).workspace(for: ref),
              PinCommands(context: AppActionContext(services: services)).isWorkspacePinned(workspace) else { return nil }
        return SidebarWorkspaceID(workspace.id)
    }

    /// A pinned workspace tile's own rows, kept under its workspace menu: Show/Hide Label.
    func tileRows(_ id: LayoutItemID) -> [NSMenuItem] {
        let menu = services.registry.makeContextMenu(for: .sidebarItem, target: ActionTargetRef(kind: .sidebarItem, id: id.rawValue),
                                                     entries: [.action("sidebar.item.toggleLabel")])
        let items = menu.items.filter { !$0.isSeparatorItem }
        menu.removeAllItems()
        return items
    }

    /// The right-click menu of a layout item: Hide only on app items.
    func layoutItemMenu(_ id: LayoutItemID) -> NSMenu? {
        let tile = model.layout.item(id), item = tile ?? model.listedItem(id)
        let entries = services.registry.contextMenuEntries(for: .sidebarItem, removing: ChiefSidebar.menuRemovals(isApp: item?.owningAppID != nil, isChief: item?.ref == .builtIn(.chief), isTile: tile != nil)
            .union(Self.pendingEdits(id, document: services.sidebarDoc.store)))
        return services.registry.makeContextMenu(for: .sidebarItem, target: ActionTargetRef(kind: .sidebarItem, id: id.rawValue),
                                                 entries: entries, customize: true)
    }

    /// The item menu rows an item `id` does not offer while its add waits for the daemon (a Chief just dragged in): an
    /// edit of its own fields waits for the echo (the planner refuses it until then), so the menu leaves it out.
    static func pendingEdits(_ id: LayoutItemID, document: SidebarDocStore?) -> Set<ActionID> {
        document?.isPending(id) == true ? ["sidebar.item.toggleLabel"] : []
    }

    func applyLayoutOp(_ op: SidebarLayoutOp) {
        // `model.layout` is the projected document shown by this window. A
        // preview-disabled projection omits rows that remain in the stored
        // legacy document, so expand item indexes before sending the op.
        let stored = services.sidebarLayout.document
        let translated = op.translatingHiddenItemIndex(from: model.layout, to: stored)
        PinCommands(context: AppActionContext(services: services)).userBandEdit(translated)
    }
}
