/// One flattened, immutable row in the collapsible file tree.
struct FileTreeRowSnapshot: Identifiable, Sendable, Equatable {
    /// Stable full-path identity.
    var id: String { node.id }
    /// Chain-compressed directory or file node.
    let node: FileTreeNode
    /// Zero-based tree indentation depth.
    let depth: Int
    /// Whether a directory is currently expanded.
    let isExpanded: Bool
}
