extension CloudTreeNodeBuilder {
    static func flattened(_ nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        var result: [CloudTreeNode] = []
        append(nodes, to: &result)
        return result
    }

    private static func append(_ nodes: [CloudTreeNode], to result: inout [CloudTreeNode]) {
        for node in nodes {
            result.append(node)
            append(node.children, to: &result)
        }
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
