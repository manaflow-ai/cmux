import Foundation

/// Validated Git metadata directories that may receive a local exclude entry.
struct ArtifactGitRepository {
    let worktreeRoot: URL
    let commonGitDirectory: URL
}
