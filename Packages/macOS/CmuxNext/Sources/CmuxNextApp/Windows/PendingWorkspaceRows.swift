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
    /// When each row's daemon workspace took over the stand-in. The row stays at its slot while the order the sidebar
    /// lists that workspace in lags (the sidebar document's projection or the personal order learns the placement a
    /// hop later, and listed it last meanwhile, so it drew at the end and sprang to its slot), at most `holdLimit`.
    /// A close in that time leaves nothing to list, so `forget` drops the row once the store no longer holds it.
    @ObservationIgnored private var takenOver: [String: ContinuousClock.Instant] = [:]
    /// How long a taken-over row may stand in for a workspace the sidebar lists elsewhere (a refused placement, or a
    /// move by someone else): then the workspace's own row lists where its order puts it.
    static let holdLimit: Duration = .seconds(2)
    @ObservationIgnored var now: () -> ContinuousClock.Instant = { .now }
    // wakeup-allow: one-shot deadline that ends a row's hold (`holdLimit`), injected for tests
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }
    /// Bumped when a hold ends, so the sidebar's tracked pass lists the workspace's own row.
    private var holdsEnded = 0
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
        takenOver[id] = nil
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
            row.window == window && (listed.contains(row.id) || elsewhere(row.id) || takenOver[row.id] != nil && !held(row.id))
        }
        guard rows.contains(where: done) else { return }
        for row in rows where done(row) { takenOver[row.id] = nil }
        rows.removeAll(where: done)
        redraws.run()
    }

    /// `listed` without the workspaces Cmd-N shows before the daemon has them: their pending rows list instead, at their
    /// slot, until the daemon's workspace takes the model over (read in the sidebar's tracked pass, so that re-runs it).
    /// After the takeover too, while `listed` puts the workspace anywhere but its slot (its order lags a hop), for at
    /// most `holdLimit`: the row never draws elsewhere and springs back.
    func listing(_ listed: [SidebarRowSection], in window: String, machines: MachineRegistry) -> [SidebarRowSection] {
        _ = holdsEnded
        let home = NewWorkspacePlacements.home(machines)
        // In press order, against the rows as drawn so far: an earlier held row sits at its slot, not where the
        // lagging order lists it, so a quick second press's slot is checked where the first one shows.
        var hidden = Set<String>()
        var drawn = listed
        for row in rows where row.window == window {
            guard let (workspace, _) = machines.workspace(id: row.id) else { continue }
            guard workspace.isProvisional || !Self.lists(row, atItsSlotIn: drawn, home: home) && holds(row.id) else { continue }
            hidden.insert(row.id)
            drawn = Self.adding([row], to: Self.removing([row.id], from: drawn), home: home)
        }
        return Self.removing(hidden, from: listed)
    }

    /// `listed` puts `row`'s workspace where its pending row goes (its own row can replace it with no move), or the
    /// pending row has no slot there (no machine section to go in): then the workspace's own row lists.
    static func lists(_ row: Row, atItsSlotIn listed: [SidebarRowSection], home: String?) -> Bool {
        let order = listed.flatMap(\.workspaces).map(\.id.rawValue)
        let slotted = adding([row], to: removing([row.id], from: listed), home: home).flatMap(\.workspaces).map(\.id.rawValue)
        return order == slotted || !slotted.contains(row.id)
    }

    /// The row still holds its slot: within `holdLimit` of its takeover (the first time the pass saw it held).
    private func holds(_ id: String) -> Bool {
        let now = now()
        guard let since = takenOver[id] else {
            takenOver[id] = now
            let sleep = sleep
            // task-owner: one hold's end; it only re-runs the pass, which lists the workspace's own row once the hold is over
            Task { [weak self] in
                try? await sleep(Self.holdLimit)
                // Only a row still held: one that reached its slot was forgotten, and nothing needs a new pass.
                guard let self, takenOver[id] != nil else { return }
                holdsEnded += 1
            }
            return true
        }
        return now - since < Self.holdLimit
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
