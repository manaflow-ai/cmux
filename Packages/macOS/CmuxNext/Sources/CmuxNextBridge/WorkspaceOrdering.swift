public import CmuxNextSidebar

/// Converts a sidebar `DropPosition` (index among the target container's
/// remaining siblings) into the daemon's root workspace index for
/// `move-workspace`.
public struct WorkspaceOrdering {
    public static let shared = Self()
    /// Root index the first moved workspace should land at, counted in the
    /// daemon order after the moved workspaces are removed. Nil when the
    /// position names a container that does not exist.
    public func rootIndex(for position: DropPosition, moving: [SidebarWorkspaceID],
                                 in sections: [SidebarRowSection]) -> Int? {
        let moved = Set(moving)
        let remaining = sections.flatMap(\.workspaces).map(\.id).filter { !moved.contains($0) }
        guard let section = sections.first(where: { $0.id == position.section }) else { return nil }
        let containers: [[SidebarWorkspaceID]]
        if let groupID = position.group {
            guard let group = section.nodes.lazy.compactMap({ node -> SidebarGroup? in
                if case let .group(group) = node, group.id == groupID { return group }
                return nil
            }).first else { return nil }
            // A group's index counts its member rows (`SidebarGroup.members`): a link, tab or app item keeps its
            // slot (no workspace), a moved workspace leaves its own.
            containers = group.members.compactMap { member in
                guard case let .workspace(workspace) = member else { return [] }
                return moved.contains(workspace.id) ? nil : [workspace.id]
            }
        } else {
            containers = section.nodes.map { $0.workspaces.map(\.id).filter { !moved.contains($0) } }.filter { !$0.isEmpty }
        }
        if position.index >= 0, let anchor = containers.dropFirst(position.index).first(where: { !$0.isEmpty })?.first {
            return remaining.firstIndex(of: anchor) ?? remaining.count
        }
        if let last = containers.last(where: { !$0.isEmpty })?.last, let index = remaining.firstIndex(of: last) {
            return index + 1
        }
        // Empty container: before the section's first remaining workspace.
        let sectionIDs = section.workspaces.map(\.id).filter { !moved.contains($0) }
        return sectionIDs.first.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
    }
}
