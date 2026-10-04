public import CoreGraphics
import Foundation

/// Where a tab dragged in from a pane would land on the sidebar.
public nonisolated enum SidebarTabDrop: Hashable, Sendable {
    /// Move the tab into this workspace (row highlights; hovering spring-loads it).
    case intoWorkspace(WorkspaceID)
    /// Create a workspace holding the tab at this slot (a gap opens).
    /// `index` follows `DropPosition` rules; nothing is excluded.
    case newWorkspace(section: SectionID, group: GroupID?, index: Int)
    /// Create a workspace holding the tab at the end of this collapsed group.
    case intoGroup(GroupID)
}

extension DropResolver {
    /// Middle band of a workspace row that means "into this workspace".
    public static let tabIntoFraction: ClosedRange<CGFloat> = 0.25...0.75

    /// Resolves an external tab drag. `base` is the layout without a gap.
    /// `sourceMachine` restricts targets to that machine's workspaces (tabs
    /// never cross daemons); nil allows any machine.
    public static func resolveTabDrop(
        y: CGFloat,
        base: SidebarLayout,
        sections: [SidebarSection],
        sourceMachine: MachineID?
    ) -> SidebarTabDrop? {
        guard !base.rows.isEmpty else { return nil }
        let (row, fraction) = hit(y: y, layout: base)
        func machineOK(_ machine: MachineID?) -> Bool {
            guard let sourceMachine else { return machine != nil }
            return machine == sourceMachine
        }
        let targetWorkspace: WorkspaceID? = switch row.key {
        case let .workspace(id): id
        case let .tab(workspace, _): workspace
        default: nil
        }
        if let id = targetWorkspace, tabIntoFraction.contains(fraction) {
            guard let ws = SidebarEdits.workspace(id, in: sections), machineOK(ws.machineID) else { return nil }
            return .intoWorkspace(id)
        }
        switch workspaceTarget(row: row, fraction: fraction, base: base, sections: sections) {
        case let .position(position)?:
            guard case let .machine(machine) = position.section, machineOK(machine) else { return nil }
            return .newWorkspace(section: position.section, group: position.group, index: position.index)
        case let .intoGroup(group)?:
            guard let (s, _) = SidebarEdits.locateGroup(group, in: sections), machineOK(sections[s].machine?.id) else { return nil }
            return .intoGroup(group)
        case nil:
            return nil
        }
    }
}
