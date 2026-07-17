import CmuxGit

enum MobileWorkspaceDiffStatusResult: Sendable {
    case repositoryNotFound
    case gitFailed
    case gitTimedOut
    case ok(repoRoot: String, files: [GitDiffSummary], truncated: Bool)
}
