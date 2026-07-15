import Foundation

/// Stable identity of one worktree and its git directory.
public nonisolated struct GitTrackedChangesRepositoryIdentity: Equatable, Hashable, Sendable {
    let workTreeRoot: String
    let gitDirectory: String

    init(repository: ResolvedGitRepository) {
        self.workTreeRoot = repository.workTreeRoot
        self.gitDirectory = repository.gitDirectory
    }

    func matches(_ repository: ResolvedGitRepository) -> Bool {
        workTreeRoot == repository.workTreeRoot && gitDirectory == repository.gitDirectory
    }
}
