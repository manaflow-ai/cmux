public import CoreGraphics

/// Why a tab dragged in from a pane cannot land on a sidebar row.
public nonisolated enum SidebarTabDropRefusal: Hashable, Sendable {
    /// The row belongs to another machine: tabs stay on their machine.
    case otherMachine
    /// The pinned area: it never hosts a new workspace.
    case pinnedArea
}

extension DropResolver {
    /// The refusal for `y` where `resolveTabDrop` gives no drop, and the
    /// row it applies to. With `resolveTabDrop` this covers every y of a
    /// non-empty sidebar (tab-dnd, 2026-10-04: every point previews either
    /// a slot or why there is none).
    public static func tabDropRefusal(y: CGFloat, base: SidebarLayout, sections: [SidebarSection],
                                      sourceMachine: MachineID?) -> (row: SidebarRowKey, reason: SidebarTabDropRefusal)? {
        guard !base.rows.isEmpty,
              resolveTabDrop(y: y, base: base, sections: sections, sourceMachine: sourceMachine) == nil else { return nil }
        let (row, _) = hit(y: y, layout: base)
        let workspace: WorkspaceID? = if case let .workspace(id) = row.key { id } else { row.workspace }
        let workspaceMachine = workspace.flatMap { SidebarEdits.workspace($0, in: sections)?.machineID }
        let sectionMachine: MachineID? = if case let .machine(machine) = row.section { machine } else { nil }
        if let sourceMachine, let machine = workspaceMachine ?? sectionMachine, machine != sourceMachine {
            return (row.key, .otherMachine)
        }
        return (row.key, row.section == .pinned ? .pinnedArea : .otherMachine)
    }
}
