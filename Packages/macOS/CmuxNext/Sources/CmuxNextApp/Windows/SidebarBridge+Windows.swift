import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

// The sidebar side of window membership: positions in this window's
// (filtered) sidebar map to the daemon's global order, and workspaces
// dragged in from another window land here.
extension SidebarBridge {
    /// Daemon root index for `position` in this window's sidebar `sections`
    /// (which list only this window's workspaces), excluding `ids`.
    func daemonRootIndex(for position: DropPosition, moving ids: [SidebarWorkspaceID], in sections: [SidebarRowSection]) -> Int? {
        guard case .machine(let machine) = position.section, let daemon = services.machines.daemon(machine: machine.rawValue) else {
            return nil
        }
        return WorkspaceOrdering.shared.globalRootIndex(for: position, moving: ids, in: sections,
            global: WindowManager.orderedIDs(of: daemon, machines: services.machines, doc: services.sidebarDoc))
    }

    /// Workspaces dragged in from another window (or moved by an action):
    /// this window takes them and selects the first; with a `position`, one
    /// daemon order command each puts them there.
    func accept(_ ids: [SidebarWorkspaceID], at position: DropPosition?) {
        guard let state else { return }
        let before = model.sections
        guard services.windows.moveWorkspaces(ids.map(\.rawValue), toWindow: state.id) else { return }
        if let position { place(ids, at: position, in: before) }
    }

    /// A group dropped into another space travels there as one group, keeping the destination window on its space.
    func accept(group: GroupID, members: [String], at position: DropPosition, from source: ProfileID?) {
        guard let state, !members.isEmpty, !services.windows.registry.value.crossesIncognito(members, to: state.id) else { return }
        let room = state.profileID, home = services.machines.local, document = services.sidebarDoc.store
        let place = document?.groupPlacement(group, at: position, model: model)
        let finish = {
            guard self.services.windows.moveWorkspaces(members, toWindow: state.id, keepingSpace: true) else { return }
            if let place { place() } else {
                self.sameTurn.syncNow(rows: true)
                self.handle(.reorderGroup(group, index: position.index))
            }
        }
        guard let source, source != room else { return finish() }
        let personal = home.store.personal.group(item: group.rawValue), previous = document?.groupRoom(group.rawValue)
        let pins = personal == nil ? members.map { WindowProfiles.qualified($0, machines: services.machines) } : []
        services.registry.trackOrReport(Task {
            if let failed = await home.moveGroupToSpace(personal?.id, members: pins, to: room) { return failed }
            document?.moveGroup(group.rawValue, toSpace: room.rawValue, from: previous)
            finish()
            return nil
        }, as: "workspaceGroup.moveToWindow")
    }

    /// Puts `ids` at `position` of this window's `sections` (taken before
    /// the move): personal order in the home session when it serves
    /// personal state, else reorder commands to the owning daemon. The rows
    /// show there at once, as after a drag, until the store holds the move:
    /// a new workspace is never drawn at its daemon slot first (cx-f6i7).
    // perf-hot: 1-row-map workspace-placement (one new workspace at its slot: its own row is mapped, never every row)
    func place(_ ids: [SidebarWorkspaceID], at position: DropPosition, in sections: [SidebarRowSection]) {
        // On the sidebar document a group is its item (`itm_g_<id>`): the document takes the move, as it takes a
        // drag, with no undo step of its own (the placement belongs to the create or drop that asked for it).
        let doc = services.sidebarDoc, placed = doc.docMachines.place(ids, at: position, model: model)
        if placed || doc.handle(.reorder(ids, to: position), bridge: self, undoable: false) {
            // The mirror holds this move, and `docMachines.place` showed the document again (no second reshow). The
            // observed rows pass follows a turn later; a burst resolves the next slot now, so that pass runs here: its row
            // feed maps only the rows that changed. `resync()` mapped every row of the window (WORKSPACE LIST 800).
            if !placed { doc.store?.reshow(live: doc.docMachines.liveRefs()) }
            if doc.store != nil { sameTurn.syncNow(rows: true) }
            return
        }
        let edit = rows.edits.add(.reorder(ids, to: position))
        if usesPersonalOrganization {
            placePersonal(ids, at: position, in: sections, edit: edit)
        } else {
            SidebarDaemonReorder.reorder(ids, to: position, in: sections, edit: edit, bridge: self)
        }
    }

    /// Workspaces dragged from another window onto a group header here.
    func accept(_ ids: [SidebarWorkspaceID], intoGroup group: GroupID) {
        guard let state else { return }
        guard services.windows.moveWorkspaces(ids.map(\.rawValue), toWindow: state.id) else { return }
        handle(.move(ids, toGroup: group))
    }

    /// Ids of this window's workspaces, in sidebar order.
    var memberIDs: [SidebarWorkspaceID] {
        guard let state else { return [] }
        return services.windows.registry.members(of: state.id).map(SidebarWorkspaceID.init)
    }
}
