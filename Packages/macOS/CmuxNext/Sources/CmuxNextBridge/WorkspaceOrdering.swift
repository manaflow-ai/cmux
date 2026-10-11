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
        let siblings: [[SidebarWorkspaceID]]
        if let groupID = position.group {
            guard let group = section.nodes.lazy.compactMap({ node -> SidebarGroup? in
                if case let .group(group) = node, group.id == groupID { return group }
                return nil
            }).first else { return nil }
            siblings = group.workspaces.map { [$0.id] }
        } else {
            siblings = section.nodes.map { $0.workspaces.map(\.id) }
        }
        let containers = siblings.map { $0.filter { !moved.contains($0) } }.filter { !$0.isEmpty }
        if containers.indices.contains(position.index), let anchor = containers[position.index].first {
            return remaining.firstIndex(of: anchor) ?? remaining.count
        }
        if let last = containers.last?.last, let index = remaining.firstIndex(of: last) {
            return index + 1
        }
        // Empty container: before the section's first remaining workspace.
        let sectionIDs = section.workspaces.map(\.id).filter { !moved.contains($0) }
        return sectionIDs.first.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
    }
}
