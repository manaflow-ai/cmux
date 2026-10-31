import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
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
        return docSections.sections(shown, session: session, workspaces: WindowProfiles.workspaces(of: daemon, in: room, machines: machines),
                                    unplacedOrder: { PersonalSidebar.personalOrder($0, of: daemon, machines: machines) })
    }

    /// The document has applied a change `shown` does not show yet (rebuilt a hop later), and `shown` does not place
    /// `workspace` (of `session`): `sections` would list it after every placed row for that hop. Only while `shown`
    /// lags: a workspace a current projection does not place (its adopt still on the way, or refused) lists its own
    /// row, so a pending row never stands in for it for long.
    static func awaitsPlacement(_ workspace: WorkspaceModel, session: String?) -> Bool {
        guard let store = SidebarDocStore.current, let shown = store.shown, store.version != store.shownVersion,
              let ref = SidebarDocSections.ref(of: workspace, session: session) else { return false }
        return shown.items[ref] == nil
    }

    /// `wrapping`: a test seam over the home daemon's document remote (a live-daemon test holds a reply).
    static func start(_ services: AppServices, layout: SidebarLayoutService,
                      wrapping: @MainActor (any SidebarDocRemote) -> any SidebarDocRemote = { $0 }) {
        let local = services.machines.local, machines = services.machines
        let serves: @MainActor () -> Bool = { local.supports(DaemonCapabilities.sidebarDoc) }
        let store = SidebarDocStore(remote: wrapping(DaemonSidebarDocRemote(connection: { local.connection }, serves: serves)))
        SidebarDocStore.current = store
        // Under `top` a new workspace lists at the daemon's slot for it until its item comes (sidebar-ordering-DESIGN.md);
        // `afterCurrent` keeps its row at the window's slot (PendingWorkspaceRows), `bottom` lists it last.
        docSections.placesNewRowsFirst = { [weak services] in
            (services?.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback) == .top
        }
        store.onRefused = { [weak services] in services?.registry.refuse($0) }
        store.onUndoPending = { [weak services] title in PinUndoStep.filling != nil ? nil : services.flatMap { PinCommands(context: AppActionContext(services: $0)).registerUndo(title: title, nil) } }
        store.onUndoable = { [weak services] (title: String, origin: AnyObject?, undo: @escaping @MainActor () -> Void) in
            // The inverse runs with its undo step as the origin, so the change it sends fills that step (the redo).
            let inverse: @MainActor () -> Void = { SidebarDocStore.undoOrigin = PinUndoStep.filling; defer { SidebarDocStore.undoOrigin = nil }; undo() }
            if let step = origin as? PinUndoStep, step.awaitsReply { return step.fillPending(title: title, inverse) }
            _ = services.map { PinCommands(context: AppActionContext(services: $0)).registerUndo(title: title, filling: origin as? PinUndoStep) { _ in inverse() } }
        }
        store.onUndoRefused = { origin in (origin as? PinUndoStep)?.abandon() }
        DaemonSidebarDocRemote.follow(local.store.session, into: store)
        if let data = local.launchSnapshotSidebarDoc {
            local.launchSnapshotSidebarDoc = nil // read once: the daemon owns the document from here on
            docMachines(machines).showLaunchSnapshot(data, in: store, connected: { local.connection != nil }, serves: serves) { layout.docLayout = $0 }
        }
        // Link rows draw the favicon at their item's icon address; an open tab's favicon address is stored on the item.
        SidebarModel.itemFavicon = { [weak services] in services?.favicons.image(for: $0, profile: .default).map { SidebarFavicon($0.cgImage) } }
        SidebarDocMachines.followFavicons(store, revision: { [weak services] in services?.favicons.revision },
                                          byOrigin: { [weak services] in services?.openTabFaviconsByOrigin() ?? [:] }, faviconKey: BookmarkURL.faviconKey(for:))
        docMachines(machines).follow(store, connected: { local.connection != nil }, serves: serves, connectedRemotes: {
            Set(machines.remoteDaemons.filter { $0.connection != nil }.compactMap(\.store.registryID))
        }, shown: { if layout.docLayout != $0 { layout.docLayout = $0 } })
    }

    /// The document over `machines`' daemon stores (`SidebarDocMachines`).
    static func docMachines(_ machines: MachineRegistry) -> SidebarDocMachines {
        SidebarDocMachines(stores: { machines.daemons.map(\.store) }, machine: { machines.daemon(machine: $0)?.store })
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
    static func orderedIDs(of daemon: DaemonService, machines: MachineRegistry) -> [String]? {
        docSections.orderedIDs(of: daemon.store, unplacedOrder: { PersonalSidebar.personalOrder($0, of: daemon, machines: machines) })
    }

    /// The document item that places sidebar workspace `id`.
    static func item(workspace id: String, _ machines: MachineRegistry) -> String? { docMachines(machines).item(workspace: id) }

    /// Sends a move intent as one document move. False: not a move, or the
    /// document is not active (the older path handles it).
    static func handle(_ intent: SidebarIntent, bridge: SidebarBridge, undoable: Bool = true) -> Bool {
        let machines = bridge.services.machines
        guard docMachines(machines).handle(intent, model: bridge.model, pinTitle: PinStrings.pinWorkspace, unpinTitle: PinStrings.unpinWorkspace,
                                           undoable: undoable)
        else { return false }
        // A pin is the home daemon's document; the workspace's own daemon (any session) gets the flag too.
        if case let .setPinned(ids, pinned) = intent { WorkspacePinFlags.live(machines).mirror(ids.map(\.rawValue), pinned: pinned) }
        return true
    }
}
