import Foundation

/// Reads a directory's git metadata directly from the on-disk repository,
/// without spawning a `git` process.
///
/// This service does the filesystem work that powers the workspace sidebar's
/// branch label, dirty indicator, and pull-request badge: resolving the
/// enclosing repository, parsing `HEAD`/`index`/`config`, and deriving the set
/// of paths a filesystem watcher should observe to know when that metadata
/// becomes stale.
///
/// It is a stateless `Sendable` value, not an `actor`, because it has no mutable
/// shared state for an actor to protect — every read is a pure function of the
/// `directory` argument. The reads do blocking filesystem work (walking to the
/// repository, parsing the git `index`/`config`), so they are `@concurrent async`:
/// `@concurrent` forces them onto the global concurrent executor regardless of
/// the caller's isolation, so `await git.workspaceMetadata(...)` from the main
/// actor offloads the work off the main thread *and* lets reads for independent
/// repositories run in parallel. (The annotation matters under Swift 6.2's
/// `NonisolatedNonsendingByDefault`, where a bare `nonisolated async` method would
/// otherwise run on the *caller's* actor — i.e. back on the main thread.) An
/// `actor` would instead funnel every read through one serial executor and, since
/// these methods never suspend internally, run them strictly sequentially — a
/// bottleneck for concurrent per-workspace reads, protecting nothing. (If this
/// ever gains an in-memory cache, promote it to an `actor` then — the mutable
/// state would justify the serialization.)
///
/// ```swift
/// let git = GitMetadataService()
/// let meta = await git.workspaceMetadata(for: "/path/to/checkout")
/// if meta.isRepository, meta.isDirty { showDirtyIndicator() }
/// ```
public struct GitMetadataService: Sendable {
    /// Creates a git-metadata service.
    public init() {}

    /// Reads a point-in-time git snapshot for `directory`.
    ///
    /// Walks upward to the nearest repository, then parses `HEAD`, the `index`,
    /// and submodule pointers. Returns ``GitWorkspaceMetadata/notARepository``
    /// when `directory` is not inside a git repository.
    ///
    /// - Parameter directory: An absolute path to inspect.
    /// - Returns: The git metadata for the enclosing repository, or
    ///   ``GitWorkspaceMetadata/notARepository`` when there is none.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return .notARepository
        }
        let trackedChanges = Self.gitTrackedChangesSnapshot(repository: repository)
        return GitWorkspaceMetadata(
            isRepository: true,
            branch: Self.gitBranchName(repository: repository),
            isDirty: trackedChanges.isDirty,
            indexSignature: trackedChanges.indexSignature,
            indexContentSignature: trackedChanges.indexContentSignature,
            headSignature: Self.gitHeadSignature(repository: repository)
        )
    }

    /// The set of existing filesystem paths whose changes can alter the metadata
    /// returned by ``workspaceMetadata(for:)`` for `directory`.
    ///
    /// Includes the working-tree root, `HEAD`, `index`, `refs`, `packed-refs`,
    /// every reachable `config` (following `include`/`includeIf`), and the
    /// equivalent paths for any gitlink submodules. Only paths that currently
    /// exist are returned, sorted for stable comparison.
    ///
    /// - Parameter directory: An absolute path to inspect.
    /// - Returns: Sorted existing paths to watch, or `nil` when `directory` is
    ///   not inside a git repository.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public func watchedPaths(for directory: String) async -> [String]? {
        Self.workspaceGitMetadataWatchedPaths(for: directory)
    }

    /// The GitHub repository slugs (`owner/name`) configured as remotes for the
    /// repository enclosing `directory`.
    ///
    /// Reads remote URLs straight from `config` (no `git` process), following
    /// `include`/`includeIf`, and orders the result `upstream`, then `origin`,
    /// then the rest, de-duplicated.
    ///
    /// - Parameter directory: An absolute path to inspect.
    /// - Returns: Ordered, de-duplicated GitHub slugs; empty when there is no
    ///   repository or no GitHub remote.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public func repositorySlugs(forDirectory directory: String) async -> [String] {
        guard let repository = Self.resolveGitRepository(containing: directory),
              let output = Self.gitRemoteVOutput(repository: repository) else {
            return []
        }
        return Self.githubRepositorySlugs(fromGitRemoteVOutput: output)
    }
}
