import CmuxNextBridge
import CmuxNextSidebar
import CmuxNextWakeups
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
        let window: String
        let machine: MachineID
        /// The row as the window lists it once the daemon has created it.
        let face: SidebarWorkspace
        let slot: WorkspaceSlot?
        let byDefault: NewWorkspaceDefaultSlot?
        /// When the row was drawn: it stands in for its workspace at most ``placeLimit`` from then.
        let pressed = ContinuousClock.now
    }

    /// How long a pending row stands in for its workspace while the window lists that workspace
    /// somewhere else (the daemon's place, before the move to the row's slot lands).
    static let placeLimit: Duration = .seconds(2)

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
    /// Bumped as a row's ``placeLimit`` passes, so the tracked `listing` lets its workspace's row list where it is.
    private var placeLimitsPassed = 0
    @ObservationIgnored private let placeTimer = DemandTimer(owner: "PendingWorkspaceRows.placeLimit")

    func add(_ row: Row, name: String) {
        rows.append(row)
        names[row.id] = (row.machine, name)
        redraws.run()
        placeTimer.schedule(after: Self.placeLimit) { @MainActor [weak self] in self?.placeLimitsPassed += 1 }
    }

    /// The create `id` failed or a close took it: its row and its name go.
    func remove(_ id: String) {
        rows.removeAll { $0.id == id }
        names[id] = nil
        takenOver.remove(id)
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
    /// Also while the sidebar document does not place the daemon's workspace yet: the document lists it last until its
    /// next projection (a hop later) places it, so its own row drew at the end and sprang to its slot.
    /// And while the window lists the workspace anywhere but the row's slot (the daemon put it last or first, and the
    /// move to the slot is on its way), for at most ``placeLimit``: the row opens where it stays and is not drawn again
    /// at the bottom and sent back (Leo 2026-10-29: "you just make it on the bottom, or you put it right next to it.
    /// What the fuck is this conflicting situation?"). Its own row replaces it at the same place, so nothing moves.
    func listing(_ listed: [SidebarRowSection], in window: String, machines: MachineRegistry) -> [SidebarRowSection] {
        _ = placeLimitsPassed
        let home = NewWorkspacePlacements.home(machines), now = ContinuousClock.now
        let waiting = Set(rows.filter { $0.window == window }.filter { row in
            guard let (workspace, daemon) = machines.workspace(id: row.id) else { return false }
            if workspace.isProvisional { return true }
            guard SidebarDocWiring.awaitsPlacement(workspace, session: daemon.store.registryID)
                || now < row.pressed.advanced(by: Self.placeLimit) && !Self.isAtSlot(row, in: listed, home: home) else { return false }
            takenOver.insert(row.id)
            return true
        }.map(\.id))
        return Self.removing(waiting, from: listed)
    }

    /// Whether `listed` shows `row`'s workspace at the slot its pending row stood at (`adding`'s rule). A slot
    /// `listed` cannot resolve (its anchor went) or a workspace it does not list holds nothing back.
    static func isAtSlot(_ row: Row, in listed: [SidebarRowSection], home: String?) -> Bool {
        let section = SectionID.machine(row.machine)
        let slot = row.slot ?? row.byDefault?.slot(for: row.id, section: section, in: listed, home: home) ?? .bottom(anchor: nil)
        guard let at = SidebarEdits.position(of: SidebarWorkspaceID(row.id), in: listed),
              let wanted = slot.position(moving: [row.id], section: section, in: listed) else { return true }
        return at == wanted
    }

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

    func rows(in window: String) -> [Row] {
        rows.filter { $0.window == window }
    }

    /// `sections` with each pending row the window does not list yet, at
    /// its slot (`NewWorkspaceDefaultSlot`), in press order. `home` is the
    /// home workspace's id.
    static func adding(_ rows: [Row], to sections: [SidebarRowSection], home: String?) -> [SidebarRowSection] {
        guard !rows.isEmpty else { return sections }
        var sections = sections
        let listed = Set(sections.flatMap(\.workspaces).map(\.id.rawValue))
        for row in rows where !listed.contains(row.id) {
            let section = SectionID.machine(row.machine)
            // No slot keeps the daemon's place: the end of the loose rows.
            let slot = row.slot ?? row.byDefault?.slot(for: row.id, section: section, in: sections, home: home) ?? .bottom(anchor: nil)
            guard let position = slot.position(moving: [row.id], section: section, in: sections) else { continue }
            SidebarEdits.insert([row.face], at: position, in: &sections)
        }
        return sections
    }
}
