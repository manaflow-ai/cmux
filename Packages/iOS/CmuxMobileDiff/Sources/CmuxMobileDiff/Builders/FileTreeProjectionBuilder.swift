/// Flattens a compressed file tree according to value-owned collapse state.
struct FileTreeProjectionBuilder: Sendable {
    /// Creates a tree projection builder.
    init() {}

    /// Creates visible rows without mutating tree or view state.
    /// - Parameters:
    ///   - roots: Chain-compressed root nodes.
    ///   - collapsedDirectoryIDs: Directory identities hidden by the user.
    /// - Returns: Depth-annotated rows in display order.
    func rows(roots: [FileTreeNode], collapsedDirectoryIDs: Set<String>) -> [FileTreeRowSnapshot] {
        var result: [FileTreeRowSnapshot] = []
        append(
            nodes: roots,
            depth: 0,
            collapsedDirectoryIDs: collapsedDirectoryIDs,
            to: &result
        )
        return result
    }

    private func append(
        nodes: [FileTreeNode],
        depth: Int,
        collapsedDirectoryIDs: Set<String>,
        to rows: inout [FileTreeRowSnapshot]
    ) {
        for node in nodes {
            let isExpanded = node.kind == .directory && !collapsedDirectoryIDs.contains(node.id)
            rows.append(FileTreeRowSnapshot(node: node, depth: depth, isExpanded: isExpanded))
            if isExpanded {
                append(
                    nodes: node.children,
                    depth: depth + 1,
                    collapsedDirectoryIDs: collapsedDirectoryIDs,
                    to: &rows
                )
            }
        }
    }
}
