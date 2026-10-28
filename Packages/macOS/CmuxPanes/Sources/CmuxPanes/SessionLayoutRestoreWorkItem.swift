/// Explicit traversal work, avoiding recursive calls on saved split trees.
enum SessionLayoutRestoreWorkItem {
    case visit(SessionWorkspaceLayoutSnapshot, depth: Int)
    case assemble(SessionSplitLayoutSnapshot)
}
