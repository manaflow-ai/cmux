import Foundation

extension SidebarSection {
    /// This section with every group's `parent` and `depth` taken from the groups it really lists.
    ///
    /// A group's indent is one gutter per level (`SidebarListView.frame(for:)`), so its depth must come
    /// only from a parent group listed before it in this section (nested groups list flat, a parent
    /// first). A group whose parent this section does not list (closed, in another section, or a
    /// stale depth from the wire) draws at the top level, aligned with every other top-level group.
    func resolvingGroupDepths() -> SidebarSection {
        var depths: [GroupID: Int] = [:]
        var resolved = self
        var changed = false
        for index in nodes.indices {
            guard case var .group(group) = nodes[index] else { continue }
            let parentDepth = group.parent.flatMap { depths[$0] }
            let parent = parentDepth == nil ? nil : group.parent
            let depth = parentDepth.map { $0 + 1 } ?? 0
            depths[group.id] = depth
            guard group.parent != parent || group.depth != depth else { continue }
            (group.parent, group.depth) = (parent, depth)
            resolved.nodes[index] = .group(group)
            changed = true
        }
        return changed ? resolved : self
    }
}
