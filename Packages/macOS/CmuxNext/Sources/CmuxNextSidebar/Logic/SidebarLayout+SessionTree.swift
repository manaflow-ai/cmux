import Foundation

nonisolated extension SidebarLayout {
    /// The session tree's drawn order of one list (a section's loose rows, or a group's members):
    /// each entry's model index and depth. A workspace whose `parents` entry is another workspace of
    /// the same list draws right after it, one level deeper, before the parent's next sibling, at
    /// any depth (who started whom). Siblings keep the list's order. A parent in another list leaves
    /// the row a root, and so does a cycle. The descendants of a `collapsed` parent do not draw (the
    /// parent shows their roll-up). `ids` are the entries' workspaces (nil: a group or an item).
    /// Without `parents` the order is the model's.
    static func treeOrder(_ ids: [WorkspaceID?], parents: [WorkspaceID: WorkspaceID]?,
                          collapsed: Set<WorkspaceID> = []) -> [(index: Int, depth: Int)] {
        guard let parents, !parents.isEmpty else { return ids.indices.map { ($0, 0) } }
        let children = treeChildren(ids, parents: parents)
        let nested = Set(children.values.joined())
        var order: [(index: Int, depth: Int)] = []
        order.reserveCapacity(ids.count)
        func visit(_ index: Int, _ depth: Int) {
            order.append((index, depth))
            guard let id = ids[index], !collapsed.contains(id) else { return }
            for child in children[id] ?? [] { visit(child, depth + 1) }
        }
        for index in ids.indices where !nested.contains(index) { visit(index, 0) }
        return order
    }

    /// Each workspace's children among `ids`, as model indices in the list's order. A child whose
    /// parent is not in the list, or whose parents run in a cycle, is nobody's child (a root).
    static func treeChildren(_ ids: [WorkspaceID?], parents: [WorkspaceID: WorkspaceID]) -> [WorkspaceID: [Int]] {
        let present = Set(ids.compactMap { $0 })
        func reachesRoot(_ id: WorkspaceID) -> Bool {
            var seen: Set<WorkspaceID> = [id]
            var current = id
            while let parent = parents[current], present.contains(parent) {
                guard seen.insert(parent).inserted else { return false }
                current = parent
            }
            return true
        }
        var children: [WorkspaceID: [Int]] = [:]
        for (index, id) in ids.enumerated() {
            guard let id, let parent = parents[id], present.contains(parent), reachesRoot(id) else { continue }
            children[parent, default: []].append(index)
        }
        return children
    }

    /// Every descendant of `id` among `ids` (model indices), for a folded parent's roll-up.
    static func treeDescendants(of id: WorkspaceID, _ ids: [WorkspaceID?], children: [WorkspaceID: [Int]]) -> [Int] {
        var found: [Int] = []
        var stack = children[id] ?? []
        while let index = stack.popLast() {
            found.append(index)
            if let child = ids[index] { stack += children[child] ?? [] }
        }
        return found
    }

    /// The fold and roll-up of the workspace at `index` drawn by `tree`: nil without children; a
    /// folded parent counts the states of everything under it (`states` by model index).
    static func treeFold(_ index: Int, _ ids: [WorkspaceID?], tree: SidebarSessionTreeState?,
                         states: (Int) -> SidebarAgentState) -> (fold: SidebarTreeFold?, rollUp: SidebarTreeRollUp?) {
        guard let tree, let id = ids[index] else { return (nil, nil) }
        let children = treeChildren(ids, parents: tree.parents)
        guard children[id]?.isEmpty == false else { return (nil, nil) }
        guard tree.collapsed.contains(id) else { return (.expanded, nil) }
        let rollUp = SidebarTreeRollUp(treeDescendants(of: id, ids, children: children).map(states))
        return (.collapsed, rollUp.isEmpty ? nil : rollUp)
    }

    /// The workspace of each node (nil: a group or an item), for `treeOrder`.
    static func workspaceIDs(_ nodes: [SidebarNode]) -> [WorkspaceID?] {
        nodes.map { node in if case let .workspace(ws) = node { ws.id } else { nil } }
    }

    /// The workspace of each group member (nil: an item), for `treeOrder`.
    static func workspaceIDs(_ members: [SidebarGroupMember]) -> [WorkspaceID?] {
        members.map { member in if case let .workspace(ws) = member { ws.id } else { nil } }
    }
}
