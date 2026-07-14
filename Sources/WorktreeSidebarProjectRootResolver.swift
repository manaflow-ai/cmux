/// Resolves every checkout to the first worktree path Git reports for its repository.
struct WorktreeSidebarProjectRootResolver: Sendable {
    private let git: any WorktreeSidebarGitOperating

    init(git: (any WorktreeSidebarGitOperating)? = nil) {
        self.git = git ?? WorktreeSidebarGitService()
    }

    @concurrent
    func projectRoot(onDiskFor directory: String) async -> String? {
        guard let worktrees = try? await git.listWorktrees(projectRootPath: directory) else {
            return nil
        }
        return worktrees.first?.path
    }
}
