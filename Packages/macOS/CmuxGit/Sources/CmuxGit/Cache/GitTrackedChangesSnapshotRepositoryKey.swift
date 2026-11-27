import Foundation

/// Repository identity fields used by the tracked-changes snapshot cache.
struct GitTrackedChangesSnapshotRepositoryKey: Equatable, Hashable, Sendable {
    let workTreeRoot: String
    let gitDirectory: String

    init(repository: ResolvedGitRepository) {
        self.workTreeRoot = repository.workTreeRoot
        self.gitDirectory = repository.gitDirectory
    }
}
