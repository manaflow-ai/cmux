/// User-interaction seam for worktree creation, deletion, and error flows.
@MainActor
protocol WorktreeSidebarDialogPresenting {
    func promptForBranchName(projectName: String) -> String?
    func confirmDeletion(
        _ inspection: WorktreeSidebarDeletionInspection,
        force: Bool
    ) -> Bool
    func presentError(_ error: Error)
    func presentPreservedBranch(name: String, reason: String)
}
