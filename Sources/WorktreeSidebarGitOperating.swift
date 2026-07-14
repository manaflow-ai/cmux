/// Narrow seam for replacing the app-side implementation with CmuxWorktrees later.
protocol WorktreeSidebarGitOperating: Sendable {
    func listWorktrees(projectRootPath: String) async throws -> [WorktreeSidebarWorktree]

    func isDirty(
        projectRootPath: String,
        worktreePath: String
    ) async throws -> Bool

    func inspectDeletion(
        projectRootPath: String,
        worktreePath: String
    ) async throws -> WorktreeSidebarDeletionInspection

    func removeWorktree(
        projectRootPath: String,
        expected: WorktreeSidebarDeletionInspection,
        force: Bool
    ) async throws -> WorktreeSidebarDeletionResult

    func createWorktree(
        projectRootPath: String,
        userInput: String
    ) async throws -> WorktreeSidebarCreationResult

    func listingWatchPaths(projectRootPath: String) async -> [String]

    func statusWatchPlan(
        worktreePath: String,
        excludingWorktreePaths: [String]
    ) async -> WorktreeSidebarStatusWatchPlan
}
