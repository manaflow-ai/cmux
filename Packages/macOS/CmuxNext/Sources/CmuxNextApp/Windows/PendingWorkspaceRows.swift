import CmuxNextBridge
import CmuxNextSidebar
import Observation

/// A new workspace's sidebar row from the press (cx-9a7wx; Lawrence
/// 2026-10-16: "This needs to be instant"): drawn at once in its final look
/// (`SidebarMapping.creatingRow`: the name the create sends, its folder, no
/// placeholder bar), at the slot the workspace will take, under the
/// workspace's own id, so the workspace's row replaces it in place with no
/// change on screen once the window lists it. A close that takes the create,
/// or a create that fails, removes the row (it closes like any row).
@MainActor @Observable
final class PendingWorkspaceRows {
    static let shared = PendingWorkspaceRows()

    struct Row: Equatable {
        /// The workspace's key, fixed at the press.
        let id: String
        var window: String
        let machine: MachineID
        /// The row as the window lists it once the daemon has created it.
        let face: SidebarWorkspace
        let slot: WorkspaceSlot?
        let byDefault: NewWorkspaceDefaultSlot?
    }

    private(set) var rows: [Row] = []
    /// The names `add` reserved, by key, until a store lists the workspace (its name counts there from then) or its create
    /// ends without one (`remove`). Not at the reply: the store can list the workspace a moment later, and a press in that
    /// gap would take the same name (the terminal path: remote, or a create with a command).
    @ObservationIgnored private var names: [String: (machine: MachineID, name: String)] = [:]
    /// Rows whose daemon workspace has taken over the stand-in (the row stays until the sidebar document places it):
    /// a close in that time leaves nothing to list, so `forget` drops the row once the store no longer holds it.
    @ObservationIgnored private var takenOver: Set<String> = []
    /// Each window's sidebar, redrawn in the turn a row comes or goes: the row draws over the rows the
    /// sidebar shows already, not after a rows pass walks every workspace on a later hop.
    let redraws = SidebarRedraws()
    /// `WindowManager.applyPendingPlacements` is running (it refreshes a rows pass that retries placements).
    @ObservationIgnored var placing = false
    /// The workspaces whose slot `WindowManager.pendingPlacements` holds and has not sent (observed: a rows pass re-runs when one goes).
    private(set) var unsentSlots: Set<String> = []

    /// A create's row in its final look (`SidebarMapping.creatingRow`) under its key: Cmd-N's, and an agent's chat open.
    func add(creating id: String, window: String, machine: MachineID, name: String, opensPage: Bool, slot: WorkspaceSlot?, byDefault: NewWorkspaceDefaultSlot?) { add(.init(id: id, window: window, machine: machine, face: SidebarMapping.shared.creatingRow(id: id, machine: machine, name: name, opensPage: opensPage), slot: slot, byDefault: byDefault), name: name) }
    func add(_ row: Row, name: String) {
        rows.append(row)
        names[row.id] = (row.machine, name)
        redraws.run()
    }

    /// The create `id` failed or a close took it: its row and its name go.
    func remove(_ id: String) {
        rows.removeAll { $0.id == id }
        names[id] = nil
        takenOver.remove(id)
        redraws.run()
    }

    /// Window `old` is now window `new` (`WindowManager.launchWindowAdopted`): its rows list there.
    func move(window old: String, to new: String) {
        guard rows.contains(where: { $0.window == old }) else { return }
        for index in rows.indices where rows[index].window == old { rows[index].window = new }
        redraws.run()
    }

    /// The names given to `machine`'s creates that no store lists yet (`listed`); the listed ones are released here.
    func reservedNames(on machine: MachineID, listed: (String) -> Bool) -> [String] {
        names = names.filter { !listed($0.key) }
        return names.values.filter { $0.machine == machine }.map(\.name)
    }

    /// Forgets the rows of `window` that it lists now (`listed`: its own row
    /// replaces this one in place) or that will not list there
    /// (`elsewhere`: another window owns it, or it is pinned to another
    /// room). Owning is not listing: a window owns a new workspace a moment
    /// before its room shows it (the pin can come after the workspace), and
    /// a row forgotten then left a gap.
    /// `held`: the store holds the workspace now (a taken-over row whose workspace closed before the document placed
    /// it has nothing left to list, so it goes too).
    func forget(in window: String, listed: Set<String>, held: (String) -> Bool, elsewhere: (String) -> Bool) {
        if !names.isEmpty { names = names.filter { !listed.contains($0.key) } } // listed: its name counts in the store now
        func done(_ row: Row) -> Bool {
            row.window == window && (listed.contains(row.id) || elsewhere(row.id) || takenOver.contains(row.id) && !held(row.id))
        }
        guard rows.contains(where: done) else { return }
        for row in rows where done(row) { takenOver.remove(row.id) }
        rows.removeAll(where: done)
        redraws.run()
    }

    /// `listed` without the workspaces Cmd-N shows before the daemon has them: their pending rows list instead, at their
    /// slot, until the daemon's workspace takes the model over (read in the sidebar's tracked pass, so that re-runs it).
    /// Also while its slot is not sent (`unsentSlots`: the placement's own rows pass runs before its move) or the document
    /// does not place it yet (the document lists it last until its next projection): its own row drew at the end first.
    func listing(_ listed: [SidebarRowSection], in window: String, machines: MachineRegistry) -> [SidebarRowSection] {
        Self.removing(ids(in: window) { id in
            guard let (workspace, daemon) = machines.workspace(id: id) else { return false }
            if workspace.isProvisional { return true }
            guard unsentSlots.contains(id) || SidebarDocWiring.awaitsPlacement(workspace, session: daemon.store.registryID) else { return false }
            takenOver.insert(id)
            return true
        }, from: listed)
    }

    /// The pending rows of `window` whose workspace the sidebar cannot draw at its slot yet (`unplaced`: Cmd-N's
    /// stand-in, or a workspace the sidebar document does not place yet): the sidebar lists the pending row for them.
    func ids(in window: String, unplaced: (String) -> Bool) -> Set<String> { Set(rows.filter { $0.window == window && unplaced($0.id) }.map(\.id)) }

    /// `sections` without the workspace rows `ids` (their pending rows list instead, at their slot).
    static func removing(_ ids: Set<String>, from sections: [SidebarRowSection]) -> [SidebarRowSection] {
        guard !ids.isEmpty else { return sections }
        return sections.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(workspace):
                    return ids.contains(workspace.id.rawValue) ? nil : node
                case var .group(group):
                    group.workspaces.removeAll { ids.contains($0.id.rawValue) }
                    return .group(group)
                case .item:
                    return node
                }
            }
            return section
        }
    }

    func rows(in window: String) -> [Row] { rows.filter { $0.window == window } }

    /// An app's `WindowManager.pendingPlacements` went from slots for `old` to slots for `new` (per id: apps share this).
    func placements(from old: [String: PendingPlacement].Keys, to new: [String: PendingPlacement].Keys) {
        if old.count != new.count || !old.allSatisfy(new.contains) { unsentSlots = unsentSlots.subtracting(old).union(new) }
    }

    /// `sections` with each pending row the window does not list yet, at
    /// its slot (`NewWorkspaceDefaultSlot`), in press order. `home` is the
    /// home workspace's id. `catchingUp`: the window's `sections` are a projection behind the sidebar document
    /// (`SidebarRows.layoutCatchingUp`).
    static func adding(_ rows: [Row], to sections: [SidebarRowSection], home: String?, catchingUp: Bool) -> [SidebarRowSection] {
        guard !rows.isEmpty else { return sections }
        var sections = sections
        let listed = Set(sections.flatMap(\.workspaces).map(\.id.rawValue))
        for row in rows where !listed.contains(row.id) {
            let section = SectionID.machine(row.machine)
            // An explicit slot is ready at the press. A default slot whose
            // current anchor is missing belongs to the stale cold layout and
            // must wait for that anchor, rather than drawing a bottom frame.
            let slot: WorkspaceSlot?
            if let explicit = row.slot {
                slot = explicit
            } else if let byDefault = row.byDefault {
                if let resolved = byDefault.slot(for: row.id, section: section, in: sections, home: home, catchingUp: catchingUp) {
                    slot = resolved
                } else if byDefault.awaitsCurrentAnchor(section: section, in: sections, home: home, catchingUp: catchingUp) {
                    continue
                } else {
                    slot = .bottom(anchor: nil)
                }
            } else {
                // No slot keeps the daemon's place: the end of the loose rows.
                slot = .bottom(anchor: nil)
            }
            guard let slot, let position = slot.position(moving: [row.id], section: section, in: sections) else { continue }
            SidebarEdits.insert([row.face], at: position, in: &sections)
        }
        return sections
    }
}
