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
        let window: String
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
    /// Each window's sidebar, redrawn in the turn a row comes or goes: the row draws over the rows the
    /// sidebar shows already, not after a rows pass walks every workspace on a later hop.
    let redraws = SidebarRedraws()

    func add(_ row: Row, name: String) {
        rows.append(row)
        names[row.id] = (row.machine, name)
        redraws.run()
    }

    /// The create `id` failed or a close took it: its row and its name go.
    func remove(_ id: String) {
        rows.removeAll { $0.id == id }
        names[id] = nil
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
    func forget(in window: String, listed: Set<String>, elsewhere: (String) -> Bool) {
        if !names.isEmpty { names = names.filter { !listed.contains($0.key) } } // listed: its name counts in the store now
        func done(_ row: Row) -> Bool { row.window == window && (listed.contains(row.id) || elsewhere(row.id)) }
        guard rows.contains(where: done) else { return }
        rows.removeAll(where: done)
        redraws.run()
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
