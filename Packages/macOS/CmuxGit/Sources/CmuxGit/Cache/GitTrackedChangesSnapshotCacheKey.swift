import Foundation

/// Complete lookup key for a reusable tracked-changes snapshot.
struct GitTrackedChangesSnapshotCacheKey: Equatable, Hashable, Sendable {
    let repository: GitTrackedChangesSnapshotRepositoryKey
    let indexStatSignature: GitIndexStatSignature
    let authority: GitTrackedChangesSnapshotAuthority

    init(
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        authority: GitTrackedChangesSnapshotAuthority
    ) {
        self.repository = GitTrackedChangesSnapshotRepositoryKey(repository: repository)
        self.indexStatSignature = indexStatSignature
        self.authority = authority
    }
}
