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
/// repository, parsing the git `index`/`config`), and are plain `nonisolated async`
/// methods (a struct's `async` methods are nonisolated): a `nonisolated async`
/// function runs on the global concurrent executor, not the caller's actor
/// (SE-0338), so `await git.workspaceMetadata(...)` from the main actor offloads
/// the work off the main thread *and* lets reads for independent repositories run
/// in parallel. An `actor` would instead funnel every read through one serial
/// executor and, since these methods never suspend internally, run them strictly
/// sequentially — a bottleneck for concurrent per-workspace reads, protecting
/// nothing. (If this ever gains an in-memory cache, promote it to an `actor`
/// then — the mutable state would justify the serialization.)
///
/// - Important: These reads are annotated `@concurrent` so they stay off the
///   caller's actor even if the package adopts the
///   `NonisolatedNonsendingByDefault` upcoming feature.
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
    @concurrent
    public nonisolated func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory, options: .full)
    }

    /// Reads a point-in-time git snapshot for `directory`, honoring `options`.
    ///
    /// Use ``GitMetadataReadOptions/sidebarLargeRepository`` for UI code where
    /// responsiveness is more important than exact dirty/index metadata.
    @concurrent
    public nonisolated func workspaceMetadata(
        for directory: String,
        options: GitMetadataReadOptions
    ) async -> GitWorkspaceMetadata {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return .notARepository
        }
        let trackedChanges: (isDirty: Bool, indexSignature: String?, indexContentSignature: String?) = {
            if options.checkWorkingTreeDirty {
                let snapshot = Self.gitTrackedChangesSnapshot(
                    repository: repository,
                    includeIndexContentSignature: options.includeIndexContentSignature
                )
                guard options.includeIndexSignatures else {
                    return (snapshot.isDirty, nil, nil)
                }
                return snapshot
            }
            guard options.includeIndexSignatures else {
                return (false, nil, nil)
            }
            let signatures = Self.gitIndexSignatures(
                repository: repository,
                includeIndexContentSignature: options.includeIndexContentSignature
            )
            return (false, signatures.indexSignature, signatures.indexContentSignature)
        }()
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
    @concurrent
    public nonisolated func watchedPaths(for directory: String) async -> [String]? {
        await watchedPaths(for: directory, options: .full)
    }

    /// The set of existing filesystem paths whose changes can alter the
    /// metadata returned by ``workspaceMetadata(for:options:)`` for `directory`.
    @concurrent
    public nonisolated func watchedPaths(
        for directory: String,
        options: GitMetadataReadOptions
    ) async -> [String]? {
        Self.workspaceGitMetadataWatchedPaths(for: directory, options: options)
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
    public nonisolated func repositorySlugs(forDirectory directory: String) async -> [String] {
        guard let repository = Self.resolveGitRepository(containing: directory),
              let output = Self.gitRemoteVOutput(repository: repository) else {
            return []
        }
        return Self.githubRepositorySlugs(fromGitRemoteVOutput: output)
    }

    /// Whether this module's `nonisolated async` methods execute off the calling
    /// thread. A seam for the test that pins the SE-0338 execution contract the
    /// reads above rely on (see the `Important` note on the type): if this module
    /// ever adopts `NonisolatedNonsendingByDefault`, execution moves onto the
    /// caller's actor, the pinning test fails, and the fix is annotating the
    /// reads `@concurrent`.
    nonisolated func executionHopsOffCallersThread() async -> Bool {
        // Thread.isMainThread is `noasync`; pthread_main_np is the supported probe.
        pthread_main_np() == 0
    }
}
