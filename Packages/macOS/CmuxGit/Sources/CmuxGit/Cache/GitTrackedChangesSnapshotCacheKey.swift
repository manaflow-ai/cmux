import Foundation

/// Complete lookup key for a reusable tracked-changes snapshot.
struct GitTrackedChangesSnapshotCacheKey: Equatable, Hashable, Sendable {
    let repository: GitTrackedChangesSnapshotRepositoryKey
    let indexStatSignature: GitIndexStatSignature
    let trackedPathEventGeneration: GitTrackedPathEventGeneration

    init(
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        trackedPathEventGeneration: GitTrackedPathEventGeneration
    ) {
        self.repository = GitTrackedChangesSnapshotRepositoryKey(repository: repository)
        self.indexStatSignature = indexStatSignature
        self.trackedPathEventGeneration = trackedPathEventGeneration
    }
}
