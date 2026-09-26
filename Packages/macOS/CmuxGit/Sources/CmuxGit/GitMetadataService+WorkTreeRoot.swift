import Foundation

extension GitMetadataService {
    /// Returns the root of the work tree that contains `directory`, the same
    /// path `git rev-parse --show-toplevel` prints, without spawning `git`.
    ///
    /// A linked worktree or submodule resolves to its own root (the directory
    /// holding its `.git` pointer file), not the main checkout.
    ///
    /// - Parameter directory: An absolute path to start from. A path to a file
    ///   is treated as its containing directory.
    /// - Returns: The work-tree root, or `nil` when `directory` is not inside a
    ///   git repository.
    @concurrent
    public nonisolated func workTreeRoot(forDirectory directory: String) async -> String? {
        Self.resolveGitRepository(containing: directory)?.workTreeRoot
    }
}
