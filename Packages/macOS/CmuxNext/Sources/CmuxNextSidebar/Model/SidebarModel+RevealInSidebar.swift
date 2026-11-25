// Reveal Workspace in Sidebar (Lawrence msg 20167: "we need a cmd shift p command like focus in sidebar/scroll to in
// sidebar"): what the model holds closed over a workspace's row. The sidebar view opens it (`SidebarView+RevealInSidebar`).
extension SidebarModel {
    /// The collapsed groups that hold workspace `id`: its own group, then each group above it (a nested group's
    /// parents), for every place the sidebar lists it. Empty when nothing folded hides it.
    func collapsedGroups(holding id: WorkspaceID) -> [GroupID] {
        var found: [GroupID] = [], seen: Set<GroupID> = []
        for path in listedPaths(of: id) where path.member != nil {
            guard case let .group(group) = sections[path.section].nodes[path.node] else { continue }
            var next: SidebarGroup? = group
            while let current = next, seen.insert(current.id).inserted {
                if current.isCollapsed { found.append(current.id) }
                next = current.parent.flatMap(self.group)
            }
        }
        return found
    }

    /// The lists (a section's loose rows, or one group's members) that list workspace `id`: the ids its "Done (N)",
    /// "Archived (N)" and "Show N more" rows fold under (``SidebarDoneFoldID``).
    func revealLists(of id: WorkspaceID) -> [SidebarDoneFoldID] {
        listedPaths(of: id).map { path in
            let section = sections[path.section]
            var group: GroupID?
            if path.member != nil, case let .group(holder) = section.nodes[path.node] { group = holder.id }
            return SidebarDoneFoldID(section: section.id, group: group)
        }
    }
}
