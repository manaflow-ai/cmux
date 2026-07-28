/// A bounded invalidation emitted by `FileExplorerStore` for its outline view.
enum FileExplorerOutlineChange {
    static let maximumScopedGitStatusPathCount = 256

    case nodeChanged(node: FileExplorerNode, reloadChildren: Bool)
    case expansionChanged(node: FileExplorerNode, isExpanded: Bool)
    /// `nil` reloads the visible viewport without collecting an unbounded path set.
    case gitStatusChanged(paths: Set<String>?)
    case selectionChanged
}
