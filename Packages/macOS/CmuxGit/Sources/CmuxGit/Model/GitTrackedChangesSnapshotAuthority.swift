import Foundation

/// Immutable cache authority stamped before a snapshot waits on the process
/// probe limiter.
public nonisolated struct GitTrackedChangesSnapshotAuthority: Equatable, Hashable, Sendable {
    let repositoryIdentity: GitTrackedChangesRepositoryIdentity
    let repositoryEpoch: UUID
    let repositoryRevision: UInt64
    let fallbackRoundID: GitFallbackRoundID?

    init(
        repositoryIdentity: GitTrackedChangesRepositoryIdentity,
        repositoryEpoch: UUID,
        repositoryRevision: UInt64,
        fallbackRoundID: GitFallbackRoundID?
    ) {
        self.repositoryIdentity = repositoryIdentity
        self.repositoryEpoch = repositoryEpoch
        self.repositoryRevision = repositoryRevision
        self.fallbackRoundID = fallbackRoundID
    }
}
