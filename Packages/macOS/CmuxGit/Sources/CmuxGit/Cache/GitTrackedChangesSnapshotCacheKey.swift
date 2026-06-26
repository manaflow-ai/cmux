import Foundation

/// Complete lookup key for a reusable tracked-changes snapshot.
struct GitTrackedChangesSnapshotCacheKey: Equatable, Hashable, Sendable {
    let repository: GitTrackedChangesSnapshotRepositoryKey
    let indexStatSignature: GitIndexStatSignature
    let trackedPathEventGeneration: UInt64

    init(
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        trackedPathEventGeneration: UInt64
    ) {
        self.repository = GitTrackedChangesSnapshotRepositoryKey(repository: repository)
        self.indexStatSignature = indexStatSignature
        self.trackedPathEventGeneration = trackedPathEventGeneration
    }
}
