/// A bounded invalidation emitted by `FileExplorerStore` for its outline view.
enum FileExplorerOutlineChange {
    static let maximumScopedGitStatusPathCount = 256

    case rootsChanged
    case nodeChanged(node: FileExplorerNode, reloadChildren: Bool)
    case expansionChanged(node: FileExplorerNode, isExpanded: Bool)
    case gitStatusChanged(FileExplorerGitStatusChangeScope)
    case selectionChanged
}
