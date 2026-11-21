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

    typealias Row = PendingWorkspaceRow

    private(set) var rows: [Row] = []
    /// The names `add` reserved, by key, until a store lists the workspace (its name counts there from then) or its create
    /// ends without one (`remove`). Not at the reply: the store can list the workspace a moment later, and a press in that
    /// gap would take the same name (the terminal path: remote, or a create with a command).
    @ObservationIgnored private var names: [String: (machine: MachineID, name: String)] = [:]
    /// Rows whose daemon workspace has taken over the stand-in (the row stays until the sidebar document places it):
    /// a close in that time leaves nothing to list, so `forget` drops the row once the store no longer holds it.
    @ObservationIgnored private var takenOver: Set<String> = []
    @ObservationIgnored private(set) var unpinned: Set<String> = [] // an agent's chat open: unpinned, its stand-in held from the add (taken over from the start)
    /// Each window's sidebar, redrawn in the turn a row comes or goes: the row draws over the rows the
    /// sidebar shows already, not after a rows pass walks every workspace on a later hop.
    let redraws = SidebarRedraws()
    /// `WindowManager.applyPendingPlacements` is running (it refreshes a rows pass that retries placements).
    @ObservationIgnored var placing = false
    /// The workspaces whose slot `WindowManager.pendingPlacements` holds and has not sent (observed: a rows pass re-runs when one goes).
    private(set) var unsentSlots: Set<String> = []
    let groupJoins = GroupJoinRows() // `agent.openSessionWorkspace --group`: joined in the pass that first lists it

    /// A create's row in its final look (`SidebarMapping.creatingRow`) under its key: Cmd-N's, and an agent's chat open.
    func add(creating id: String, window: String, machine: MachineID, name: String, opensPage: Bool, slot: WorkspaceSlot?, byDefault: NewWorkspaceDefaultSlot?, unpinned: Bool = false) { if unpinned { self.unpinned.insert(id); takenOver.insert(id) }; add(.init(id: id, window: window, machine: machine, face: SidebarMapping.shared.creatingRow(id: id, machine: machine, name: name, opensPage: opensPage), slot: slot, byDefault: byDefault), name: name) }
    func add(_ row: Row, name: String) {
        rows.append(row)
        names[row.id] = (row.machine, name)
        redraws.run()
    }

    /// The create `id` failed or a close took it: its row and its name go.
    func remove(_ id: String) {
        rows.removeAll { $0.id == id }
        names[id] = nil
        takenOver.remove(id); unpinned.remove(id); groupJoins.release(id)
        redraws.run()
    }

    /// The row `id` was dropped at `slot` while its create runs (`WindowManager.reslotCreates`): it draws there now.
    func reslot(_ id: String, to slot: WorkspaceSlot) { if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].slot = slot; rows[i].byDefault = nil; redraws.run() } }

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
        let gone = Set(rows.filter(done).map(\.id)); guard !gone.isEmpty else { return } // judged once: `done` reads the sets cleared below
        takenOver.subtract(gone); unpinned.subtract(gone)
        rows.removeAll { gone.contains($0.id) }
        redraws.run()
    }

    /// `listed` without the workspaces Cmd-N shows before the daemon has them: their pending rows list instead, at their
    /// slot, until the daemon's workspace takes the model over (read in the sidebar's tracked pass, so that re-runs it).
    /// Also while its slot is not sent (`unsentSlots`: the placement's own rows pass runs before its move) or the document
    /// does not place it yet (the document lists it last until its next projection): its own row drew at the end first.
    /// `doc`: the app's own sidebar document.
    func listing(_ listed: [SidebarRowSection], in window: String, machines: MachineRegistry, doc: SidebarDocument) -> [SidebarRowSection] {
        SidebarEdits.removing(ids(in: window) { id in
            guard let (workspace, daemon) = machines.workspace(id: id) else { return false }
            if workspace.isProvisional { return true }
            guard unsentSlots.contains(id) || doc.awaitsPlacement(workspace, session: daemon.store.registryID) else { return false }
            takenOver.insert(id)
            return true
        }.union(doc.isActive ? groupJoins.hidden(in: listed, window: window, catchingUp: doc.catchingUp) : []), from: listed)
    }

    /// The pending rows of `window` whose workspace the sidebar cannot draw at its slot yet (`unplaced`: Cmd-N's
    /// stand-in, or a workspace the sidebar document does not place yet): the sidebar lists the pending row for them.
    func ids(in window: String, unplaced: (String) -> Bool) -> Set<String> { Set(rows.filter { $0.window == window && unplaced($0.id) }.map(\.id)) }

    func rows(in window: String) -> [Row] { rows.filter { $0.window == window && !groupJoins.holds($0.id) } } // a held grouped create: no slot, so no stand-in

    /// An app's `WindowManager.pendingPlacements` went from slots for `old` to slots for `new` (per id: apps share this).
    func placements(from old: [String: PendingPlacement].Keys, to new: [String: PendingPlacement].Keys) {
        if old.count != new.count || !old.allSatisfy(new.contains) { unsentSlots = unsentSlots.subtracting(old).union(new) }
    }
}
