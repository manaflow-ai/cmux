import Foundation

nonisolated extension SidebarLayout {
    /// The session tree's drawn order of one list (a section's loose rows, or a group's members):
    /// each entry's model index and depth. A workspace whose `parents` entry is another workspace of
    /// the same list draws right after it, one level deeper, before the parent's next sibling, at
    /// any depth (who started whom). Siblings keep the list's order. A parent in another list leaves
    /// the row a root, and so does a cycle. The descendants of a `collapsed` parent do not draw (the
    /// parent shows their roll-up), nor those of one `folded` says folds at its depth.
    /// `ids` are the entries' workspaces (nil: a group or an item).
    /// Without `parents` the order is the model's. `children`: `treeChildren`, when the caller has it.
    static func treeOrder(_ ids: [WorkspaceID?], parents: [WorkspaceID: WorkspaceID]?,
                          collapsed: Set<WorkspaceID> = [], folded: ((WorkspaceID, Int) -> Bool)? = nil,
                          children known: [WorkspaceID: [Int]]? = nil) -> [(index: Int, depth: Int)] {
        guard let parents, !parents.isEmpty else { return ids.indices.map { ($0, 0) } }
        let children = known ?? treeChildren(ids, parents: parents)
        let nested = Set(children.values.joined())
        let folds = folded ?? { id, _ in collapsed.contains(id) }
        var order: [(index: Int, depth: Int)] = []
        order.reserveCapacity(ids.count)
        func visit(_ index: Int, _ depth: Int) {
            order.append((index, depth))
            guard let id = ids[index], !folds(id, depth) else { return }
            for child in children[id] ?? [] { visit(child, depth + 1) }
        }
        for index in ids.indices where !nested.contains(index) { visit(index, 0) }
        return order
    }

    /// Each workspace's children among `ids`, as model indices in the list's order. A child whose
    /// parent is not in the list, or whose parents run in a cycle, is nobody's child (a root).
    /// One pass: each workspace's answer is remembered, so a chain is walked once, not once per link.
    static func treeChildren(_ ids: [WorkspaceID?], parents: [WorkspaceID: WorkspaceID]) -> [WorkspaceID: [Int]] {
        let present = Set(ids.compactMap { $0 })
        var rooted: [WorkspaceID: Bool] = [:]
        func reachesRoot(_ id: WorkspaceID) -> Bool {
            var path: [WorkspaceID] = []
            var onPath: Set<WorkspaceID> = []
            var next: WorkspaceID? = id
            var answer = true
            while let current = next {
                if let known = rooted[current] { answer = known; break }
                guard onPath.insert(current).inserted else { answer = false; break } // a cycle
                path.append(current)
                next = parents[current].flatMap { present.contains($0) ? $0 : nil } // nil: a root
            }
            for node in path { rooted[node] = answer }
            return answer
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

    /// The fold and roll-up of the workspace at `index`, drawn at `depth` by `tree`, whose list's `children`
    /// (`treeChildren`) the caller computed once: nil without children; a folded parent counts the
    /// states of everything under it (`states` by model index).
    static func treeFold(_ index: Int, depth: Int, _ ids: [WorkspaceID?], tree: SidebarSessionTreeState?, children: [WorkspaceID: [Int]],
                         states: (Int) -> SidebarAgentState) -> (fold: SidebarTreeFold?, rollUp: SidebarTreeRollUp?) {
        guard let tree, let id = ids[index] else { return (nil, nil) }
        guard children[id]?.isEmpty == false else { return (nil, nil) }
        guard tree.isFolded(id, depth: depth) else { return (.expanded, nil) }
        let rollUp = SidebarTreeRollUp(treeDescendants(of: id, ids, children: children).map(states))
        return (.collapsed, rollUp.isEmpty ? nil : rollUp)
    }

    /// One loose row as the session tree draws it (`treeRows`): its model index, depth, chevron and roll-up.
    struct TreeRow {
        var index = 0, depth = 0
        var fold: SidebarTreeFold?
        var rollUp: SidebarTreeRollUp?
    }

    /// A section's loose rows (`nodes`) in the session tree's drawn order, each with its depth and,
    /// on a parent, its fold and roll-up. A filter opens every fold: the order and the chevrons both
    /// draw it open. Without `tree` the order is the model's, flat.
    static func treeRows(_ nodes: [SidebarNode], tree live: SidebarSessionTreeState?, filtering: Bool) -> [TreeRow] {
        treeRows(workspaceIDs(nodes), workspace: { if case let .workspace(ws) = nodes[$0] { ws } else { nil } },
                 tree: live, filtering: filtering)
    }

    /// `treeRows` of one list, a section's loose rows or a group's members: `ids` its workspaces, `workspace` by index.
    static func treeRows(_ ids: [WorkspaceID?], workspace: @escaping (Int) -> SidebarWorkspace?, tree live: SidebarSessionTreeState?,
                         filtering: Bool) -> [TreeRow] {
        let tree = live.map { shown in
            var tree = shown
            if filtering { (tree.collapsed, tree.foldsDeep) = ([], false) }
            return tree
        }
        let children = tree.map { treeChildren(ids, parents: $0.parents) } ?? [:]
        let state: (Int) -> SidebarAgentState = { i in
            guard let ws = workspace(i) else { return .idle }
            return SidebarAgentState.of(ws, lane: live?.states[ws.id])
        }
        let folded: ((WorkspaceID, Int) -> Bool)? = tree.map { shown in { id, depth in shown.isFolded(id, depth: depth) } }
        return treeOrder(ids, parents: tree?.parents, folded: folded, children: children).map { entry in
            let (fold, rollUp) = treeFold(entry.index, depth: entry.depth, ids, tree: tree, children: children, states: state)
            return TreeRow(index: entry.index, depth: entry.depth, fold: fold, rollUp: rollUp)
        }
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
