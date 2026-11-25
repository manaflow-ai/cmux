import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextApps
import CmuxNextBridge
import CmuxNextChiefPetWiring
import CmuxNextCompat
import CmuxNextDaemon
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
    /// The registry action each built-in runs (`SidebarBandItems`).
    static var builtInActions: [SidebarBuiltIn: ActionID] { SidebarBandItems.builtInActions }

    /// Runs item `id` as a click does: a top-section item that stands for a
    /// page opens that page in this window (TOP-SECTION-ITEMS-ARE-PAGES).
    func activateLayoutItem(_ id: LayoutItemID, opensWorkspace: Bool = false) {
        if machineSections.activate(id) { return }; guard let item = model.layout.item(id) ?? model.listedItem(id) else { return WhatsNewPage.activateClientItem(id, services: services, in: state) }
        if ChiefSidebar.opensChief(item.ref) { return inThisWindow { _ = services.registry.perform(ChiefSidebar.openAction, invocation: ActionInvocation(origin: .user)) } }
        if let region = model.layout.region(of: id), let route = TopPageRoute(item.ref, in: region),
           TopPages.show(route, services: services, in: state) != nil { return }
        activate(item.ref, opensWorkspace: opensWorkspace)
    }

    /// Runs a sidebar item (sidebar-sections.md 2); pinned tabs, pages, spaces: SidebarBridge+PinnedItems.
    func activate(_ ref: LayoutItemRef, opensWorkspace: Bool = false) {
        if let builtIn = ref.builtIn, let action = Self.builtInActions[builtIn] {
            var invocation = ActionInvocation(origin: .user)
            if opensWorkspace, builtIn == .newTerminal { invocation.arguments["toggleWorkspace"] = .bool(true) }
            inThisWindow { _ = services.registry.perform(action, invocation: invocation) }
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
            inThisWindow { _ = services.registry.perform(action, invocation: ActionInvocation(arguments: arguments, origin: .user)) }
        default: break
        }
    }

    private func inThisWindow(_ body: () -> Void) { services.windows.dispatching(eventFrom: state.flatMap { services.windows.controller(for: $0.id)?.window }, body) }

    /// What an app item's click runs (R63/R64): `cmux.apps.open {app}` (it
    /// opens the app's screen or page as the manifest says) once it is
    /// registered. INTERIM until then: Home and the App Store keep their
    /// show actions, every other app opens its page (`app.open`).
    static func appActivation(_ app: String, registered: (ActionID) -> Bool) -> (ActionID, [String: ActionValue]) {
        let actions = SidebarBridgeRules().appActivation(app) // best first; the last always runs
        let chosen = actions.first { registered(ActionID(rawValue: $0.action)) } ?? actions.last ?? ("app.open", true)
        return (ActionID(rawValue: chosen.action), chosen.appArgument ? ["app": .string(app)] : [:])
    }

    /// Writes `model.itemInfo` in this turn (the window's first frame reads it, `SidebarFirstFrame`) and keeps it current: a
    /// built-in whose action this build does not register draws dimmed; with it, the drawn order's hold (`SidebarLaunchOrderHold`).
    func observeSections() {
        let model = model
        let registry = services.registry
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
        let uploads = services.chiefAvatarUploads, pictures = services.chiefSidebarPictures
        let home = services.home
        // A band item's page face (the list rows' own), read in the observation so a favicon that loads replaces the item's globe.
        let pageFace = { [weak services] (workspace: WorkspaceModel, tab: TabModel, work: TabModel?) in services?.sidebarPageFace(workspace, tab: tab, work: work) ?? .init() }, faces = faceBuffers
        typealias Inputs = (SidebarLayoutDocument, Int, Int, [ActionID: String], [LayoutItemRef: SidebarItemInfo], URL?, Bool, Bool, [LayoutItem])
        let hold = SidebarLaunchOrderHold(home: store, document: { [weak services] in services?.sidebarDoc.store }).follow(model)
        // The first pass runs in this call, in the turn that makes the sidebar; the pass's task follows the later changes.
        // Also observed: Labs (the App Store item shows only with it on), `experiments.forum` (the Forum item likewise), the apps client (installs, hides), the unread count, Home's unread conversations, the built-ins' shortcuts (tooltips) and
        // the workspaces tiles and top rows name. The selected item comes from the one selection.
        // The built-ins listed in a group or a machine list (a Chief dragged there) draw their band look too.
        sectionsPass = SidebarSectionsPass(model: model, hold: hold, read: { () -> Inputs in
            _ = (apps.apps, ChiefSidebar.shared.status, DesignSettings.shared.appLanguage) // the language: titles are read below
            return (service.document, NotificationCenterService.unreadCount(store), home.unreadConversations.count,
                    Self.builtInShortcuts(registry), SidebarWorkspaceItems.workspaceInfos(service.document, refs: refs, autoNames: settings?.snapshot.sidebarSections.autoNamesWorkspaces ?? true, pageFace: pageFace, faces: faces), chiefPicture(), settings?.snapshot.showsAppStore == true, settings?.snapshot.showsForum == true,
                    model.listedBuiltIns)
        }, values: { (inputs: Inputs) in
            let (layout, unread, homeUnread, shortcuts, workspaces, picture, showsStore, showsForum, listed) = inputs
            // `model.layout` is written with the rows it projects (SidebarBridge.show).
            let infos = Self.itemInfo(for: SidebarRows.visibleLayout(layout), registered: { registry.action(for: $0) != nil },
                                      unread: unread, homeUnread: homeUnread, showsStore: showsStore, showsForum: showsForum,
                                      app: SidebarAppItemInfo(client: apps, showsStore: showsStore).info, shortcut: { shortcuts[$0] },
                                      workspace: { workspaces[$0] }, chiefFavicon: pictures.favicon(still: picture, image: picture.flatMap(uploads.image(at:))), listed: listed)
            return (infos, AppPresence(apps.apps).suppressed)
        })
    }

    /// Built-in tooltips use the same shortcut text as menus.
    static func builtInShortcuts(_ registry: ActionRegistry) -> [ActionID: String] {
        var shortcuts: [ActionID: String] = [:]
        for action in builtInActions.values {
            if let shortcut = registry.shortcutDisplay(for: action) { shortcuts[action] = shortcut }
        }
        return shortcuts
    }

    /// The band items' values (`SidebarBandItems.info`).
    static func itemInfo(for layout: SidebarLayoutDocument, registered: (ActionID) -> Bool, unread: Int = 0, homeUnread: Int = 0, showsStore: Bool = true, showsForum: Bool = false,
                         app: (String) -> SidebarItemInfo = { SidebarItemInfo.fallback(for: .app($0)) }, shortcut: (ActionID) -> String? = { _ in nil },
                         workspace: (LayoutItemRef) -> SidebarItemInfo? = { _ in nil }, chiefFavicon: SidebarFavicon? = nil, listed: [LayoutItem] = []) -> [LayoutItemID: SidebarItemInfo] {
        SidebarBandItems.info(for: layout, registered: registered, unread: unread, homeUnread: homeUnread, showsStore: showsStore, showsForum: showsForum, app: app,
                              shortcut: shortcut, workspace: workspace, chiefFavicon: chiefFavicon, listed: listed)
    }

    /// A layout change from this sidebar (a drag, an inline edit): sent to
    /// the layout owner; a refusal shows in the refusal HUD.
    /// The right-click menu of a section: Hide only on an app section, Hide
    /// Section only on Recents (`SidebarHiddenSections`).
    func layoutSectionMenu(_ id: LayoutSectionID) -> NSMenu? {
        // The widget area's header: Edit Widgets and Add Widget (it is not in the layout document).
        if id == SidebarAppSections.widgetSectionID { return withWidgetItems(NSMenu()) }
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
        let entries = services.registry.contextMenuEntries(for: .sidebarItem, removing: ChiefSidebar.menuRemovals(isApp: item?.owningAppID != nil, isChief: item.map { SidebarTransientItem.chiefAnchors.contains($0.ref) } == true, isTile: tile != nil)
            .union(Self.pendingEdits(id, document: services.sidebarDoc.store)).union(services.sidebarLayout.document.isTopRow(id) ? ["sidebar.item.remove"] : []))
        return services.registry.makeContextMenu(for: .sidebarItem, target: ActionTargetRef(kind: .sidebarItem, id: id.rawValue),
                                                 entries: entries, customize: true)
    }

    /// The item menu rows an item `id` does not offer while its add waits for the daemon (a Chief just dragged in): an
    /// edit of its own fields waits for the echo (the planner refuses it until then), so the menu leaves it out.
    static func pendingEdits(_ id: LayoutItemID, document: SidebarDocStore?) -> Set<ActionID> {
        document?.isPending(id) == true ? ["sidebar.item.toggleLabel"] : []
    }

    /// `menu` with Edit Widgets and Add Widget at its end (the sidebar's background, the widget header).
    func withWidgetItems(_ menu: NSMenu?) -> NSMenu? {
        (container.sidebarView.appSections as? SidebarAppSections)?.widgets?.appendingMenuItems(to: menu) ?? menu
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
