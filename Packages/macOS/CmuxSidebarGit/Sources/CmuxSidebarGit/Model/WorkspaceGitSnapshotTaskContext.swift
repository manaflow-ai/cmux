import CmuxGit

/// The cache-reuse inputs captured when a per-directory snapshot task starts.
struct WorkspaceGitSnapshotTaskContext: Equatable, Sendable {
    let trackedPathEventGeneration: GitTrackedPathEventGeneration?
}
