import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

/// The sidebar document (sidebar-v2, `sidebar-doc-v1`): one store for the home session; its bands shown through
/// `SidebarLayoutService.docLayout`, its machine order read by `PersonalSidebar`, and every move (drag, keyboard,
/// pin, section drop) sent as one `sidebar.move`. Without the capability nothing here runs: the older path stays.
@MainActor
enum SidebarDocWiring {
    static let docSections = SidebarDocSections()
    /// `daemon`'s sections in the document's order, or nil when the document is not shown.
    static func sections(of daemon: DaemonService, room: ProfileID, machines: MachineRegistry) -> [CmuxNextDaemon.SidebarSection]? {
        guard let shown = SidebarDocStore.current?.shown, let session = daemon.store.registryID else { return nil }
        return docSections.sections(shown, session: session, workspaces: WindowProfiles.workspaces(of: daemon, in: room, machines: machines))
    }

    static func start(_ services: AppServices, layout: SidebarLayoutService) {
        let local = services.machines.local, machines = services.machines
        let serves: @MainActor () -> Bool = { local.supports(DaemonCapabilities.shared.sidebarDoc) }
        let store = SidebarDocStore(remote: DaemonSidebarDocRemote(connection: { local.connection }, serves: serves))
        SidebarDocStore.current = store
        store.onRefused = { [weak services] in services?.registry.refuse($0) }
        store.onUndoable = { [weak services] (title: String, undo: @escaping @MainActor () -> Void) in
            guard let services else { return }
            PinCommands(context: AppActionContext(services: services)).registerUndo(title: title) { _ in undo() }
        }
        DaemonSidebarDocRemote.follow(local.store.session, into: store)
        // Link rows draw the favicon at their item's icon address; an open tab's favicon address is stored on the item.
        SidebarModel.itemFavicon = { [weak services] in services?.favicons.image(for: $0, profile: .default).map { SidebarFavicon($0.cgImage) } }
        // task-owner: the app's services (live for the app); event-driven (Observation)
        Task { [weak services] in
            // An open tab's favicon address can change while its image is cached already (no favicon revision): watch
            // the addresses too, read once per change into one origin -> favicon table for every link.
            var last: [String: String]?
            var lastVersion: UInt64?
            for await (revision, version, byOrigin) in ObservationStream({ (services?.favicons.revision, store.version, services?.openTabFaviconsByOrigin() ?? [:]) }) {
                _ = revision
                NotificationCenter.default.post(name: SidebarModel.itemFaviconsChanged, object: nil)
                guard byOrigin != last || version != lastVersion else { continue } // a tab change that moves no favicon address
                (last, lastVersion) = (byOrigin, version)
                store.storeIconURLs { page in URL(string: page).flatMap(BookmarkURL.faviconKey(for:)).flatMap { byOrigin[$0] } }
            }
        }
        // task-owner: the app's services (live for the app); event-driven (Observation)
        Task { for await _ in ObservationStream({ (local.connection != nil, serves()) }) { store.refresh() } }
        // task-owner: the app's services; one view call per document or live-set change
        Task {
            for await live in ObservationStream({ () -> [SidebarDocWorkspaceRef] in _ = (store.version, store.isActive); return liveRefs(machines) }) {
                store.show(live: live, connectedRemotes: Set(machines.daemons.filter { $0 !== local && $0.connection != nil }.compactMap(\.store.registryID)))
                if layout.docLayout != store.shown?.layout { layout.docLayout = store.shown?.layout }
            }
        }
    }

    /// Why band edits are refused now: nil while the document is active (it takes them), else the older owner's reason.
    static func layoutUnavailableReason(_ layout: SidebarLayoutService) -> String? {
        isActive ? nil : layout.unavailableReason
    }

    /// The document is active: band edits go to it, not to the older layout owner.
    static var isActive: Bool { SidebarDocStore.current.map { $0.isActive && $0.shown != nil } ?? false }

    /// Sends band edits (section and item actions) as one document change
    /// while the document is active; false when it is not (the older layout
    /// owner takes them). Throws the refusal for an edit the document has no
    /// op for. `undoable`: a user's change (one undo step titled `title`).
    static func sendLayout(_ ops: [SidebarLayoutOp], over layout: SidebarLayoutDocument, title: String, undoable: Bool) throws -> Bool {
        guard isActive, let store = SidebarDocStore.current else { return false }
        do {
            try store.send(layout: ops, over: layout, title: title, undoable: undoable)
        } catch let gap as SidebarDocStore.LayoutOpGap {
            throw ActionFailure(message: SidebarSectionStrings.describe(gap))
        } catch let refusal as SidebarDocSendRefusal {
            throw ActionFailure(message: refusal.message)
        }
        return true
    }

    /// Every workspace of `daemon` in the document's order (window membership order), whatever its room; nil off the document path.
    static func orderedIDs(of daemon: DaemonService) -> [String]? {
        guard isActive, let shown = SidebarDocStore.current?.shown, let session = daemon.store.registryID else { return nil }
        let listed = docSections.sections(shown, session: session, workspaces: daemon.store.workspaces).flatMap(\.workspaces).map(\.id)
        let seen = Set(listed)
        return listed + daemon.store.workspaces.map(\.id).filter { !seen.contains($0) }
    }

    static func liveRefs(_ machines: MachineRegistry) -> [SidebarDocWorkspaceRef] {
        machines.daemons.flatMap { daemon in daemon.store.workspaces.compactMap { SidebarDocSections.ref(of: $0, session: daemon.store.registryID) } }
    }

    /// The document item that places sidebar workspace `id`.
    static func item(workspace id: String, _ machines: MachineRegistry) -> String? {
        guard let store = SidebarDocStore.current, let (workspace, daemon) = machines.workspace(id: id),
              let ref = SidebarDocSections.ref(of: workspace, session: daemon.store.registryID) else { return nil }
        return store.shown?.items[ref]
    }

    /// The drag half for `bridge`'s model while the document is active.
    static func drag(_ bridge: SidebarBridge) -> SidebarDocDrag? {
        guard let store = SidebarDocStore.current, store.isActive, store.shown != nil else { return nil }
        let machines = bridge.services.machines
        return SidebarDocDrag(item: { key in
            switch key {
            case .workspace(let id): item(workspace: id.rawValue, machines)
            case .group(let group): group.rawValue
            default: nil
            }
        }, section: { id in
            switch id {
            case .pinned, .custom: SidebarDocStore.pinnedSection // SidebarDocDrag answers .custom itself
            case .machine(let machine): machines.daemon(machine: machine.rawValue)?.store.registryID.flatMap { store.shown?.machineSections[$0] }
            }
        }, begin: { store.acceptance(dragging: $0) }, drop: { store.move($0, to: $1, title: SidebarDocStore.moveTitle) }, adoptRef: { id in
            guard let (workspace, daemon) = machines.workspace(id: id.rawValue), let ref = SidebarDocSections.ref(of: workspace, session: daemon.store.registryID) else { return nil }
            return ["session_id": ref.sessionID, "workspace_id": ref.workspaceID, "workspace_key": workspace.key?.rawValue ?? workspace.id]
        })
    }

    /// Sends a move intent as one document move. False: not a move, or the
    /// document is not active (the older path handles it).
    static func handle(_ intent: SidebarIntent, bridge: SidebarBridge) -> Bool {
        guard let store = SidebarDocStore.current, let drag = drag(bridge) else { return false }
        return store.handle(intent, model: bridge.model, drag: drag, pinTitle: PinStrings.pinWorkspace, unpinTitle: PinStrings.unpinWorkspace)
    }
}
