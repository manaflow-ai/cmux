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
    /// The shared rule: `sidebar_edits` `joinable_groups`.
    nonisolated static func joinableGroups(for id: WorkspaceID, in sections: [SidebarSection]) -> [SidebarGroup] {
        var request = RustEditRequest("joinable_groups", sections: RustSidebarEdits(sections).sections)
        request.id = id.rawValue
        let joinable = Set(RustSidebarClient.call("sidebar_edits", request, as: [String].self) ?? [])
        return groups(in: sections).filter { joinable.contains($0.id.rawValue) }
    }
}
