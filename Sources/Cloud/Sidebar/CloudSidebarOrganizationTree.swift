/// Resolves organization against the actual catalog-built tree. No row is
/// inserted, removed, renamed, reparented, or recreated by organization.
struct CloudSidebarOrganizationTree {
    let nodes: [CloudTreeNode]

    /// The outline root has no AppKit item; its persisted parent ID is empty.
    struct Siblings {
        let parent: CloudTreeNode?
        let children: [CloudTreeNode]
        var id: String { parent?.id ?? "" }
    }

    func siblings(of id: String) -> Siblings? {
        if nodes.contains(where: { $0.id == id && $0.canOrganize }) {
            return Siblings(parent: nil, children: nodes)
        }
        guard let parent = parent(of: id) else { return nil }
        return Siblings(parent: parent, children: parent.children)
    }

    func parent(of id: String) -> CloudTreeNode? {
        for node in nodes {
            if node.children.contains(where: { $0.id == id && $0.canOrganize }) { return node }
            if let parent = CloudSidebarOrganizationTree(nodes: node.children).parent(of: id) { return parent }
        }
        return nil
    }

    func arrange(using state: CloudSidebarOrganizationState) -> [CloudTreeNode] {
        arrange(nodes, parent: "", state: state)
    }

    private func arrange(_ nodes: [CloudTreeNode], parent: String,
                         state: CloudSidebarOrganizationState) -> [CloudTreeNode] {
        let eligible = nodes.filter(\.canOrganize)
        let byID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = eligible.map(\.id)
        let order = state.ordered(ids, parent: parent)
        var ordered = order.makeIterator()
        let arranged = nodes.map { node -> CloudTreeNode in
            guard node.canOrganize, let id = ordered.next(), let replacement = byID[id] else { return node }
            replacement.isPinned = state.isPinned(id, parent: parent)
            return replacement
        }
        for node in arranged {
            node.children = arrange(node.children, parent: node.id, state: state)
        }
        return arranged
    }
}
