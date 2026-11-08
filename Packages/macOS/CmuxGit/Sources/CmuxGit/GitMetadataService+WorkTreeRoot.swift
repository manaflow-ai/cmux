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
    /// immediately.
    ///
    /// - Parameters:
    ///   - directory: An absolute path to start from. A path to a file is
    ///     treated as its containing directory.
    ///   - timeout: The longest the caller waits.
    /// - Returns: ``GitWorkTreeRootLookup/root(_:)``,
    ///   ``GitWorkTreeRootLookup/notInRepository`` when the walk finished
    ///   without finding one, or ``GitWorkTreeRootLookup/unavailable`` when
    ///   it timed out or an earlier walk is still running.
    public nonisolated func workTreeRoot(
        forDirectory directory: String,
        timeout: Duration = .seconds(5)
    ) async -> GitWorkTreeRootLookup {
        await workTreeRoot(forDirectory: directory, timeout: timeout, runner: Self.workTreeRootRunner)
    }

    /// ``workTreeRoot(forDirectory:timeout:)`` on a given runner, so tests
    /// don't share the app's.
    nonisolated func workTreeRoot(
        forDirectory directory: String,
        timeout: Duration,
        runner: BoundedBlockingRunner
    ) async -> GitWorkTreeRootLookup {
        let outcome = await runner.run(timeout: timeout) { deadline -> GitWorkTreeRootLookup in
            if let root = Self.resolveGitRepository(containing: directory, deadline: deadline)?.workTreeRoot {
                return .root(root)
            }
            // The walk also gives up at the deadline, which isn't a finding.
            return deadline > DispatchTime.now() ? .notInRepository : .unavailable
        }
        switch outcome {
        case .finished(let lookup):
            return lookup
        case .timedOut, .busy:
            return .unavailable
        }
    }
}

/// The result of ``GitMetadataService/workTreeRoot(forDirectory:timeout:)``.
public enum GitWorkTreeRootLookup: Sendable, Equatable {
    /// The root of the work tree containing the directory.
    case root(String)
    /// The walk reached the filesystem root without finding a repository.
    case notInRepository
    /// The walk timed out, or an earlier walk is still stuck, so whether the
    /// directory is in a repository is unknown.
    case unavailable
}
