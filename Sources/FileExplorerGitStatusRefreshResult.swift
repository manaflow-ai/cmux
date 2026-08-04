struct FileExplorerGitStatusRefreshResult: Sendable {
    let status: [String: GitFileStatus]
    let diff: FileExplorerGitStatusDiff
}
