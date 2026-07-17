/// The checkout created by the Project Worktrees `+` action.
struct WorktreeSidebarCreationResult: Equatable, Sendable {
    let branchName: String
    let worktreePath: String
}
