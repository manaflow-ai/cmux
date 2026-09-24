/// Resolves organization against the actual catalog-built tree. No row is
/// inserted, removed, renamed, reparented, or recreated by organization.
struct CloudSidebarOrganizationTree {
    let nodes: [CloudTreeNode]

    func parent(of id: String) -> CloudTreeNode? {
        for node in nodes {
            if node.children.contains(where: { $0.id == id && $0.canOrganize }) { return node }
            if let parent = CloudSidebarOrganizationTree(nodes: node.children).parent(of: id) { return parent }
        }
        return nil
    }

    func arrange(using state: CloudSidebarOrganizationState) -> [CloudTreeNode] {
        for node in nodes {
            let eligible = node.children.filter(\.canOrganize)
            let byID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var ordered = state.ordered(eligible.map(\.id), parent: node.id).makeIterator()
            node.children = node.children.map { child in
                guard child.canOrganize, let id = ordered.next(), let replacement = byID[id] else { return child }
                replacement.isPinned = state.isPinned(id, parent: node.id)
                return replacement
            }
            _ = CloudSidebarOrganizationTree(nodes: node.children).arrange(using: state)
        }
        return nodes
    }
}
