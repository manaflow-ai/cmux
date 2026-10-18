import Foundation

extension SidebarModel {
    /// Every group the sidebar lists, in row order.
    public var groups: [SidebarGroup] {
        sections.flatMap(\.nodes).compactMap { node in
            if case let .group(group) = node { return group }
            return nil
        }
    }

    /// The group listing workspace `id`, if any.
    public func group(containing id: WorkspaceID) -> SidebarGroup? {
        groups.first { $0.workspaces.contains { $0.id == id } }
    }
}

extension SidebarSection {
    /// The section's containers, as a sort orders them: its loose rows, then each group's rows.
    public var containers: [(group: GroupID?, workspaces: [WorkspaceID])] {
        let loose = nodes.compactMap { node -> WorkspaceID? in
            if case let .workspace(workspace) = node { return workspace.id }
            return nil
        }
        let groups = nodes.compactMap { node -> (group: GroupID?, workspaces: [WorkspaceID])? in
            if case let .group(group) = node { return (group.id, group.workspaces.map(\.id)) }
            return nil
        }
        return [(nil, loose)] + groups
    }
}
