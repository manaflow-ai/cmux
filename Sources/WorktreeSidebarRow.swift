/// Immutable value passed across the lazy-list snapshot boundary.
struct WorktreeSidebarRow: Identifiable, Equatable, Sendable {
    let worktree: WorktreeSidebarWorktree
    let status: WorktreeSidebarStatus

    var id: String { worktree.id }
}
