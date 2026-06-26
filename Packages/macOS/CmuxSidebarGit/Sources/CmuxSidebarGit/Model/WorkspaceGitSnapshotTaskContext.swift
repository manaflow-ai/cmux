/// The cache-reuse inputs captured when a per-directory snapshot task starts.
nonisolated struct WorkspaceGitSnapshotTaskContext: Equatable, Sendable {
    let trackedPathEventGeneration: UInt64?
}
