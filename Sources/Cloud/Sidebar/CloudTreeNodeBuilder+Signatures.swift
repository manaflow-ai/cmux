extension CloudTreeNodeBuilder {
    static func flattened(_ nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }

    /// Row identities, order and kinds — a change here needs `reloadData`.
    static func structureSignature(_ nodes: [CloudTreeNode]) -> [String] {
        flattened(nodes).map { "\($0.id)|\($0.structureTag)|\($0.children.count)" }
    }

    /// Everything a row displays — a change here with an equal structure signature is
    /// applied to the existing rows in place.
    static func contentSignature(_ nodes: [CloudTreeNode]) -> [CloudTreeNodeContentSnapshot] {
        flattened(nodes).map(\.contentSnapshot)
    }
}
