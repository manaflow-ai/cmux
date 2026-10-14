import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSidebar

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
        let serves = { local.supports(DaemonCapabilities.shared.sidebarDoc) }
        let store = SidebarDocStore(remote: DaemonSidebarDocRemote(connection: { local.connection }, serves: serves))
        SidebarDocStore.current = store
        store.onRefused = { [weak services] in services?.registry.refuse($0) }
        store.onUndoable = { [weak services] title, undo in
            guard let services else { return }
            PinCommands(context: AppActionContext(services: services)).registerUndo(title: title) { _ in undo() }
        }
        DaemonSidebarDocRemote.follow(local.store.session, into: store)
        // task-owner: the app's services (live for the app); event-driven (Observation)
        Task { for await _ in ObservationStream({ (local.connection != nil, serves()) }) { store.refresh() } }
        // task-owner: the app's services; one view call per document or live-set change
        Task {
            for await live in ObservationStream({ () -> [SidebarDocWorkspaceRef] in _ = (store.version, store.isActive); return liveRefs(machines) }) {
                store.show(live: live)
                if layout.docLayout != store.shown?.layout { layout.docLayout = store.shown?.layout }
            }
        }
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
            case .pinned: SidebarDocStore.pinnedSection
            case .machine(let machine): machines.daemon(machine: machine.rawValue)?.store.registryID.flatMap { store.shown?.machineSections[$0] }
            }
        }, begin: { store.acceptance(dragging: $0) }, drop: { store.move($0, to: $1, title: SidebarDocStore.moveTitle) })
    }

    /// Sends a move intent as one document move. False: not a move, or the
    /// document is not active (the older path handles it).
    static func handle(_ intent: SidebarIntent, bridge: SidebarBridge) -> Bool {
        guard let store = SidebarDocStore.current, let drag = drag(bridge) else { return false }
        let model = bridge.model, title = SidebarDocStore.moveTitle
        func items(_ ids: [SidebarWorkspaceID]) -> [String] { ids.compactMap { drag.item(.workspace($0)) } }
        func layoutMove(_ moving: [String], _ section: LayoutSectionID, _ index: Int) {
            store.move(moving, to: SidebarDocDrag.target(section, index: index, moving: moving, layout: model.layout), title: title)
        }
        switch intent {
        case .reorder(let ids, let position):
            guard let target = drag.target(position, moving: items(ids), model: model) else { return false }
            store.move(items(ids), to: target, title: title)
        case .reorderGroup(let group, let index):
            guard let section = model.sections.first(where: { $0.nodes.contains { $0.id == .group(group) } }),
                  let target = drag.target(DropPosition(section: section.id, index: index), moving: [group.rawValue], model: model) else { return false }
            store.move([group.rawValue], to: target, title: title)
        case .move(let ids, let group):
            guard let section = store.records.items[group.rawValue]?.section else { return false }
            store.move(items(ids), to: SidebarDocTarget(section: section, parent: group.rawValue), title: title)
        case .setPinned(let ids, let pinned):
            pinned ? store.pin(items(ids), title: PinStrings.pinWorkspace) : store.unpin(items(ids), title: PinStrings.unpinWorkspace)
        case .setGroupPinned(let group, let pinned):
            // The old "pin group" is plain Pin: the group moves into Pinned.
            pinned ? store.pin([group.rawValue], title: PinStrings.pinWorkspace) : store.unpin([group.rawValue], title: PinStrings.unpinWorkspace)
        case .dropOnLayoutSection(let ids, let section, let index):
            layoutMove(items(ids), section, index)
        case .layout(.itemMove(let id, let section, let index)):
            layoutMove([id.rawValue], section, index)
        case .toggleCollapse(.group):
            model.apply(intent) // client view state on the document
        default:
            return false
        }
        return true
    }
}
