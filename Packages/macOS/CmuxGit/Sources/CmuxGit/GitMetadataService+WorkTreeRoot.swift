import Dispatch
import Foundation

extension GitMetadataService {
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
    /// The walk runs off the cooperative executor and gives up at `timeout`,
    /// so a stalled network mount cannot hold the caller indefinitely.
    ///
    /// - Parameters:
    ///   - directory: An absolute path to start from. A path to a file is
    ///     treated as its containing directory.
    ///   - timeout: How long the walk may take before it returns `nil`.
    /// - Returns: The work-tree root, or `nil` when `directory` is not inside
    ///   a git repository or the walk timed out.
    public nonisolated func workTreeRoot(
        forDirectory directory: String,
        timeout: Duration = .milliseconds(1_500)
    ) async -> String? {
        let components = timeout.components
        let nanoseconds = Double(components.seconds) * 1_000_000_000
            + Double(components.attoseconds) / 1_000_000_000
        let boundedNanoseconds = Int(min(max(0, nanoseconds), Double(Int32.max) * 1_000))
        return await resolveGitRepositoryBlocking(
            containing: directory,
            deadline: .now() + .nanoseconds(boundedNanoseconds)
        )?.workTreeRoot
    }
}
