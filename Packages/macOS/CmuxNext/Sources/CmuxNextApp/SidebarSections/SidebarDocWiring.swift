import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar
import Foundation

/// The App's half of its sidebar document (`SidebarDocument`, built by AppServices): its bands shown through
/// `SidebarLayoutService.docLayout`, its machine order read by `PersonalSidebar`, and every move (drag, keyboard, pin,
/// section drop) sent as one `sidebar.move`. Without the capability nothing here runs: the older path stays.
extension SidebarDocument {
    /// `daemon`'s sections in the document's order, or nil when the document is not shown.
    func sections(of daemon: DaemonService, room: ProfileID, machines: MachineRegistry) -> [CmuxNextDaemon.SidebarSection]? {
        guard let shown = store?.shown, let session = daemon.store.registryID else { return nil }
        return docSections.sections(shown, session: session, workspaces: WindowProfiles.workspaces(of: daemon, in: room, machines: machines),
                                    room: room.rawValue, unplacedOrder: { PersonalSidebar.personalOrder($0, of: daemon, machines: machines, doc: self) })
    }

    /// Builds this app's store and follows its home daemon; once per app (`AppServices.sidebarLayout`'s first read).
    /// `wrapping`: a test seam over the home daemon's document remote (a live-daemon test holds a reply).
    func start(_ services: AppServices, layout: SidebarLayoutService,
               wrapping: @MainActor (any SidebarDocRemote) -> any SidebarDocRemote = { $0 }) {
        let local = services.machines.local, machines = services.machines
        let serves: @MainActor () -> Bool = { local.supports(DaemonCapabilities.sidebarDoc) }
        let store = SidebarDocStore(remote: wrapping(DaemonSidebarDocRemote(connection: { local.connection }, serves: serves)))
        self.store = store
        // Under `top` a new workspace lists at the daemon's slot for it until its item comes (sidebar-ordering-DESIGN.md);
        // `afterCurrent` keeps its row at the window's slot (PendingWorkspaceRows), `bottom` lists it last.
        docSections.placesNewRowsFirst = { [weak services] in
            (services?.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback) == .top
        }
        store.onRefused = { [weak services] in services?.registry.refuse($0) }
        store.newItemRoom = { [weak services] in services?.windows.active?.state.profileID.rawValue }
        store.onUndoPending = { [weak services] title in PinUndoStep.filling != nil ? nil : services.flatMap { PinCommands(context: AppActionContext(services: $0)).registerUndo(title: title, nil) } }
        store.onUndoable = { [weak services, weak store] (title: String, origin: AnyObject?, undo: @escaping @MainActor () -> Void) in
            // The inverse runs with its undo step as the origin, so the change it sends fills that step (the redo).
            let inverse: @MainActor () -> Void = { store?.undoOrigin = PinUndoStep.filling; defer { store?.undoOrigin = nil }; undo() }
            if let step = origin as? PinUndoStep, step.awaitsReply { return step.fillPending(title: title, inverse) }
            _ = services.map { PinCommands(context: AppActionContext(services: $0)).registerUndo(title: title, filling: origin as? PinUndoStep) { _ in inverse() } }
        }
        store.onUndoRefused = { origin in (origin as? PinUndoStep)?.abandon() }
        DaemonSidebarDocRemote.follow(local.store.session, into: store)
        if let data = local.launchSnapshotSidebarDoc {
            local.launchSnapshotSidebarDoc = nil // read once: the daemon owns the document from here on
            docMachines.showLaunchSnapshot(data, in: store, connected: { local.connection != nil }, serves: serves) { layout.docLayout = $0 }
        }
        // An open tab's favicon address is stored on its link item (each window's rows draw it, `SidebarModel.itemFavicon`).
        SidebarDocMachines.followFavicons(store, revision: { [weak services] in services?.favicons.revision },
                                          byOrigin: { [weak services] in services?.openTabFaviconsByOrigin() ?? [:] }, faviconKey: BookmarkURL.faviconKey(for:))
        docMachines.follow(store, connected: { local.connection != nil }, serves: serves, connectedRemotes: {
            Set(machines.remoteDaemons.filter { $0.connection != nil }.compactMap(\.store.registryID))
        }, shown: { if layout.docLayout != $0 { layout.docLayout = $0 } })
    }

    /// Why band edits are refused now: nil while the document is active (it takes them), else the older owner's reason.
    func layoutUnavailableReason(_ layout: SidebarLayoutService) -> String? {
        isActive ? nil : layout.unavailableReason
    }

    /// Sends band edits (section and item actions) as one document change
    /// while the document is active; false when it is not (the older layout
    /// owner takes them). Throws the refusal for an edit the document has no
    /// op for. `undoable`: a user's change (one undo step titled `title`).
    func sendLayout(_ ops: [SidebarLayoutOp], over layout: SidebarLayoutDocument, title: String, undoable: Bool) throws -> Bool {
        guard let store = activeStore else { return false }
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
    func orderedIDs(of daemon: DaemonService, machines: MachineRegistry) -> [String]? {
        docSections.orderedIDs(of: daemon.store, unplacedOrder: { PersonalSidebar.personalOrder($0, of: daemon, machines: machines, doc: self) })
    }

    /// Sends a move intent as one document move. False: not a move, or the
    /// document is not active (the older path handles it).
    func handle(_ intent: SidebarIntent, bridge: SidebarBridge, undoable: Bool = true) -> Bool {
        guard docMachines.handle(intent, model: bridge.model, pinTitle: PinStrings.pinWorkspace, unpinTitle: PinStrings.unpinWorkspace,
                                 undoable: undoable)
        else { return false }
        // A pin is the home daemon's document; the workspace's own daemon (any session) gets the flag too.
        if case let .setPinned(ids, pinned) = intent { WorkspacePinFlags.live(bridge.services.machines).mirror(ids.map(\.rawValue), pinned: pinned) }
        return true
    }
}
