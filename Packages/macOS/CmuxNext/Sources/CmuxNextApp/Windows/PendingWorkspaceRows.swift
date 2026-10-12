import CmuxNextBridge
import CmuxNextSidebar
import CmuxNextWakeups
import Observation

/// A new workspace's sidebar row from the press (cx-9a7wx): a window's
/// creates run one at a time (`WorkspaceLanes`), so at key-repeat speed the
/// last one is reported seconds after its press. Its row shows at once, as
/// a placeholder at the slot the workspace will take, under the workspace's
/// own id, and the workspace's row replaces it in place once the window
/// lists it. A close that takes the create, or a create that fails, removes
/// the row. The row waits ``grace`` first: a create the daemon reports by then
/// changes the sidebar once, in the frame that shows the workspace and its
/// page, never a placeholder row beside the old content (cx-21zkz).
@MainActor @Observable
final class PendingWorkspaceRows {
    static let shared = PendingWorkspaceRows()

    struct Row: Equatable {
        /// The workspace's key, fixed at the press.
        let id: String
        let window: String
        let machine: MachineID
        /// The name asked for; empty draws the placeholder bar.
        let title: String
        let slot: WorkspaceSlot?
        let byDefault: NewWorkspaceDefaultSlot?
    }

    /// About the time a local create takes to be reported when its window has no other create
    /// waiting (Cmd-N: ~70 ms in the frame strips); a queued create shows its row after it.
    static let grace: Duration = .milliseconds(150)

    private(set) var rows: [Row] = []
    /// Rows within their ``grace``, by workspace id.
    @ObservationIgnored private var waiting: [String: DemandTimer] = [:]

    func add(_ row: Row) {
        let timer = DemandTimer(owner: "PendingWorkspaceRows.grace")
        waiting[row.id] = timer
        timer.schedule(after: Self.grace) { @MainActor [weak self] in
            guard let self, waiting.removeValue(forKey: row.id) != nil else { return }
            rows.append(row)
        }
    }

    func remove(_ id: String) {
        waiting.removeValue(forKey: id)?.cancel()
        rows.removeAll { $0.id == id }
    }

    /// Forgets the rows of workspaces a window now owns: their own rows show.
    func forget(owned: (String) -> Bool) {
        for id in waiting.keys where owned(id) { waiting.removeValue(forKey: id)?.cancel() }
        guard rows.contains(where: { owned($0.id) }) else { return }
        rows.removeAll { owned($0.id) }
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
            let workspace = SidebarWorkspace(id: WorkspaceID(row.id), machineID: row.machine, title: row.title, rowState: .placeholder)
            SidebarEdits.insert([workspace], at: position, in: &sections)
        }
        return sections
    }

    /// `sections` without placeholder rows, which no daemon knows: a new
    /// workspace's slot is resolved against the rows it will sit among.
    static func withoutPlaceholders(_ sections: [SidebarRowSection]) -> [SidebarRowSection] {
        sections.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(workspace):
                    return workspace.rowState == .placeholder ? nil : node
                case var .group(group):
                    group.workspaces.removeAll { $0.rowState == .placeholder }
                    return .group(group)
                }
            }
            return section
        }
    }
}
