public extension SidebarEdits {
    /// Every group of a sidebar, personal groups included, in sidebar order.
    nonisolated static func groups(in sections: [SidebarSection]) -> [SidebarGroup] {
        sections.flatMap(\.nodes).compactMap { node -> SidebarGroup? in
            if case .group(let group) = node { group } else { nil }
        }
    }

    /// The groups a right-clicked workspace's Move to Group lists, in sidebar order: every group
    /// of its window's sidebar it may join (`canMove`: a group holds one machine row's
    /// workspaces), without the group it is in already (moving there only reorders it).
    nonisolated static func joinableGroups(for id: WorkspaceID, in sections: [SidebarSection]) -> [SidebarGroup] {
        groups(in: sections).filter { group in
            !group.workspaces.contains { $0.id == id } && canMove([id], toGroup: group.id, in: sections)
        }
    }
}
