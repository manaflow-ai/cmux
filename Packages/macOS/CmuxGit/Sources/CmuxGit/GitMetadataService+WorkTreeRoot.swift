import Dispatch
import Foundation

extension GitMetadataService {
    /// Serializes work-tree-root walks so a hung mount parks at most one thread.
    private static let workTreeRootRunner = BoundedBlockingRunner(label: "com.cmux.git-work-tree-root")

    /// Returns the root of the work tree that contains `directory`, found by
    /// walking up for the nearest `.git` directory or `gitdir:` pointer file,
    /// without spawning `git`.
    ///
    /// For an ordinary checkout, linked worktree, or submodule this is the
    /// directory holding its `.git` entry, which usually matches
    /// `git rev-parse --show-toplevel`. It can differ where Git does more than
    /// a filesystem walk: the walk follows the logical path it is given
    /// rather than resolving symlinks, and it does not special-case paths
    /// inside a `.git` directory.
    ///
    /// The walk runs on a dedicated serial queue, one at a time. The caller
    /// waits at most `timeout`, even if a probe on a hung network mount never
    /// returns, and a call made while an earlier walk is still stuck returns
    /// `nil` immediately.
    ///
    /// - Parameters:
    ///   - directory: An absolute path to start from. A path to a file is
    ///     treated as its containing directory.
    ///   - timeout: The longest the caller waits.
    /// - Returns: The work-tree root, or `nil` when `directory` is not inside
    ///   a git repository, the walk timed out, or an earlier walk is still
    ///   running.
    public nonisolated func workTreeRoot(
        forDirectory directory: String,
        timeout: Duration = .seconds(5)
    ) async -> String? {
        await Self.workTreeRootRunner.run(timeout: timeout) { deadline in
            Self.resolveGitRepository(containing: directory, deadline: deadline)?.workTreeRoot
        }
    }
}
