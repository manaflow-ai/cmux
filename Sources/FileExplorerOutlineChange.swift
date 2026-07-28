/// A bounded invalidation emitted by `FileExplorerStore` for its outline view.
enum FileExplorerOutlineChange {
    case nodeChanged(node: FileExplorerNode, reloadChildren: Bool)
    case expansionChanged(node: FileExplorerNode, isExpanded: Bool)
    case gitStatusChanged(nodes: [FileExplorerNode])
    case selectionChanged
}
