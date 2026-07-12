import Foundation

/// A completed snapshot paired with the task identity that produced it.
struct WorkspaceGitSnapshotApply: Sendable {
    let taskID: UUID
    let authority: DetachedCompletionAuthority
    let snapshot: InitialWorkspaceGitMetadataSnapshot
}
