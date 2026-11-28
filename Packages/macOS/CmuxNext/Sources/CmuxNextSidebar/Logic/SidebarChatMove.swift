import Foundation

/// A chat moving to another machine, as its sidebar row shows it (the App's ``ChatMoves``): the row travels to the
/// machine's section at once, which the list draws as the row sliding there, then says the step and fills its bar
/// until the move ends. A failed move ends it too: the row slides back.
public nonisolated struct SidebarChatMove: Hashable, Sendable {
    /// The chat's workspace row.
    public var workspace: WorkspaceID
    /// The machine whose section the row goes to; nil (not known yet, or the chat shares its workspace with other
    /// tabs, which stay) keeps the row where it is.
    public var machine: MachineID?
    /// The step and about how long is left; nil before the first line.
    public var line: String?
    /// 0...1; nil draws the bar indeterminate.
    public var fraction: Double?

    public init(workspace: WorkspaceID, machine: MachineID?, line: String?, fraction: Double?) {
        self.workspace = workspace
        self.machine = machine
        self.line = line
        self.fraction = fraction
    }

    /// `sections` with each moving chat's row in its machine's section (last, at the section's top level), saying
    /// `line` (else `moving`) under its title with the bar. A row or machine `sections` does not list is left alone.
    /// Pure: no clock, no I/O.
    public static func applying(_ moves: [SidebarChatMove], to sections: [SidebarSection], moving: String) -> [SidebarSection] {
        guard !moves.isEmpty else { return sections }
        var sections = sections
        for move in moves {
            let show = { (row: inout SidebarWorkspace) in
                row.status = move.line ?? moving
                row.progress = SidebarProgress(value: move.fraction)
            }
            let target = move.machine.flatMap { machine in sections.firstIndex { $0.machine?.id == machine } }
            if let target, sections[target].workspaces.first(where: { $0.id == move.workspace }) == nil {
                var removed = SidebarEdits.removeWorkspaces([move.workspace], from: &sections)
                guard var row = removed.popLast() else { continue }
                show(&row)
                // A travelling row is never selected, closed, renamed or dragged: it is neither machine's row until
                // the chat's own row lands. A row that stays (its other tabs stay) keeps working.
                row.rowState = .moving
                row.isClosable = false
                row.machineID = sections[target].machine?.id ?? row.machineID
                sections[target].nodes.append(.workspace(row))
            } else {
                for s in sections.indices { sections[s].nodes = sections[s].nodes.map { node in node.updatingWorkspace(move.workspace, show) } }
            }
        }
        return sections
    }
}

private extension SidebarNode {
    /// This node with workspace `id` (itself, or a member of this group) changed by `change`.
    nonisolated func updatingWorkspace(_ id: WorkspaceID, _ change: (inout SidebarWorkspace) -> Void) -> SidebarNode {
        switch self {
        case var .workspace(ws) where ws.id == id:
            change(&ws)
            return .workspace(ws)
        case var .group(group) where group.workspaces.contains(where: { $0.id == id }):
            group.setMembers(group.members.map { member in
                guard case var .workspace(ws) = member, ws.id == id else { return member }
                change(&ws)
                return .workspace(ws)
            })
            return .group(group)
        default:
            return self
        }
    }
}
