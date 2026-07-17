/// Identifies how Git removed a worktree registration.
enum WorktreeSidebarDeletionRemoval: Equatable, Sendable {
    case removed
    case pruned
}
