import CmuxNextBridge
import CmuxNextCloudUI
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
        let scoped = sections.filter { $0.id == position.section }
        guard let local = WorkspaceOrdering.shared.rootIndex(for: position, moving: ids, in: scoped) else { return nil }
        let moved = Set(ids.map(\.rawValue))
        let localOrder = scoped.flatMap(\.workspaces).map(\.id.rawValue).filter { !moved.contains($0) }
        let global = WindowManager.orderedIDs(of: daemon, machines: services.machines).filter { !moved.contains($0) }
        return SidebarMembership.globalIndex(localIndex: local, local: localOrder, global: global)
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

    /// Puts `ids` at `position` of this window's `sections` (taken before
    /// the move): personal order in the home session when it serves
    /// personal state, else reorder commands to the owning daemon. The rows
    /// show there at once, as after a drag, until the store holds the move:
    /// a new workspace is never drawn at its daemon slot first (cx-f6i7).
    func place(_ ids: [SidebarWorkspaceID], at position: DropPosition, in sections: [SidebarRowSection]) {
        // On the sidebar document a group is its item (`itm_g_<id>`): the document takes the move, as it takes a
        // drag, with no undo step of its own (the placement belongs to the create or drop that asked for it).
        if SidebarDocWiring.docMachines(services.machines).place(ids, at: position, model: model) { return }
        if SidebarDocWiring.handle(.reorder(ids, to: position), bridge: self, undoable: false) { return }
        let edit = rows.add(.reorder(ids, to: position))
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

// Kept Cloud workspaces that no machine lists (P-AUSTIN B7): signed out of cmux Cloud, Cloud off,
// their machine paused or not loaded. The window keeps them; its sidebar lists each under its machine.
extension SidebarBridge {
    /// This window's kept Cloud workspaces as rows, with the headers of machines that have no section:
    /// the name and look each row last had (this window's saved sidebar), the reason as its second line.
    /// Only in the window's default space: the space of a kept workspace is not saved, and a row in
    /// every space would be noise in each.
    func absentCloudRows(_ state: WindowState) -> (rows: [SidebarWorkspace], headers: [MachineID: SidebarMachine]) {
        guard state.profileID == .defaultProfile else { return ([], [:]) }
        let windows = services.windows
        let absent = windows.registry.members(of: state.id).compactMap { id in windows.cloudAbsence(of: id).map { (id, $0) } }
        guard !absent.isEmpty else { return ([], [:]) }
        let saved = savedRows(state.id)
        var headers: [MachineID: SidebarMachine] = [:]
        let rows = absent.map { id, absence in
            let machine = MachineID(windows.seenMachine[id] ?? "")
            var row = saved.rows[SidebarWorkspaceID(id)]
                ?? SidebarWorkspace(id: SidebarWorkspaceID(id), machineID: machine, title: CloudWorkspaceAbsence.untitledWorkspace)
            row.machineID = machine
            row.rowState = .stale
            row.isClosable = false
            row.progress = nil
            row.stage = absence.rowStatus
            if headers[machine] == nil {
                let name = services.machines.session(machine.rawValue)?.machine.title ?? saved.machineNames[machine] ?? CloudWorkspaceAbsence.unnamedMachine
                headers[machine] = SidebarMachine(id: machine, name: name, kind: .cloud,
                                                  status: absence == .paused ? .paused : absence == .connecting ? .connecting : .offline)
            }
            return row
        }
        return (rows, headers)
    }

    /// The name a kept Cloud workspace's row shows (its window's title and card say the same).
    func absentRowTitle(_ id: String) -> String {
        guard let state else { return CloudWorkspaceAbsence.untitledWorkspace }
        return model.workspace(SidebarWorkspaceID(id))?.title ?? savedRows(state.id).rows[SidebarWorkspaceID(id)]?.title
            ?? CloudWorkspaceAbsence.untitledWorkspace
    }

    /// The rows and machine names this window's sidebar last saved: this run's last save, else the launch's.
    private func savedRows(_ window: String) -> (rows: [SidebarWorkspaceID: SidebarWorkspace], machineNames: [MachineID: String]) {
        let saved = snapshotRecorder.lastSnapshot ?? services.sidebarSnapshots.launchDocument.snapshot(for: window, fallback: false)
        let sections = saved?.sidebarSections ?? []
        let rows = Dictionary(sections.flatMap(\.workspaces).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(sections.compactMap { $0.machine.map { ($0.id, $0.name) } }.filter { !$0.1.isEmpty }, uniquingKeysWith: { first, _ in first })
        return (rows, names)
    }

    /// A gesture on a kept Cloud workspace's row: a click shows it (why it is not connected) in this
    /// window without claiming it again; a close, drag or rename waits for its machine (the row snaps
    /// back). False for intents on other rows.
    func handleAbsent(_ intent: SidebarIntent, state: WindowState) -> Bool {
        let windows = services.windows
        func isAbsent(_ id: SidebarWorkspaceID) -> Bool { windows.cloudAbsence(of: id.rawValue) != nil }
        switch intent {
        case .select(let id) where isAbsent(id):
            model.apply(intent)
            windows.select(id.rawValue, in: state)
            windows.controller(for: state.id)?.showWorkspace(requested: state.workspaceID)
            return true
        case .close(let ids) where ids.contains(where: isAbsent),
             .reorder(let ids, _) where ids.contains(where: isAbsent),
             .move(let ids, _) where ids.contains(where: isAbsent):
            resync()
            return true
        case .rename(let id, _) where isAbsent(id):
            resync()
            return true
        default:
            return false
        }
    }
}
