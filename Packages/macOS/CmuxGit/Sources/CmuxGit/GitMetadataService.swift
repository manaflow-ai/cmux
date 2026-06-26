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
/// It is a `Sendable` value facade over blocking filesystem reads plus a small
/// actor-isolated tracked-change cache. The reads do blocking filesystem work
/// (walking to the repository, parsing the git `index`/`config`), and are plain
/// `nonisolated async` methods (a struct's `async` methods are nonisolated): a
/// `nonisolated async` function runs on the global concurrent executor, not the
/// caller's actor (SE-0338), so `await git.workspaceMetadata(...)` from the main
/// actor offloads the work off the main thread *and* lets reads for independent
/// repositories run in parallel. The cache is an actor because it is mutable
/// shared state, but it is only consulted through the watcher-generation API;
/// direct reads without a watcher generation always do a conservative scan.
///
/// - Important: If the package ever adopts the `NonisolatedNonsendingByDefault`
///   upcoming feature, a bare `nonisolated async` method flips to running on the
///   *caller's* actor (the main thread, here). At that point these reads must be
///   annotated `@concurrent` to keep them off the main thread.
///
/// ```swift
/// let git = GitMetadataService()
/// let meta = await git.workspaceMetadata(for: "/path/to/checkout")
/// if meta.isRepository, meta.isDirty { showDirtyIndicator() }
/// ```
public struct GitMetadataService: Sendable {
    let fileStatusReader: any GitFileStatusReading
    private let trackedChangesSnapshotCache: GitTrackedChangesSnapshotCache

    /// Creates a git-metadata service.
    public init() {
        self.fileStatusReader = SystemGitFileStatusReader()
        self.trackedChangesSnapshotCache = GitTrackedChangesSnapshotCache()
    }

    init(
        fileStatusReader: any GitFileStatusReading,
        trackedChangesSnapshotCache: GitTrackedChangesSnapshotCache = GitTrackedChangesSnapshotCache()
    ) {
        self.fileStatusReader = fileStatusReader
        self.trackedChangesSnapshotCache = trackedChangesSnapshotCache
    }

    /// Reads a point-in-time git snapshot for `directory`.
    ///
    /// Walks upward to the nearest repository, then parses `HEAD`, the `index`,
    /// and submodule pointers. Returns ``GitWorkspaceMetadata/notARepository``
    /// when `directory` is not inside a git repository.
    ///
    /// - Parameter directory: An absolute path to inspect.
    /// - Returns: The git metadata for the enclosing repository, or
    ///   ``GitWorkspaceMetadata/notARepository`` when there is none.
    public nonisolated func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory, trackedPathEventGeneration: nil)
    }

    /// Reads a point-in-time git snapshot for `directory`, allowing callers
    /// with a repository filesystem-event generation token to enable
    /// tracked-change reuse when no relevant event has arrived.
    ///
    /// - Parameters:
    ///   - directory: An absolute path to inspect.
    ///   - trackedPathEventGeneration: A caller-owned, namespaced generation
    ///     that changes whenever the watched repository paths report a
    ///     filesystem event. Pass `nil` when no watcher is active; the read
    ///     then avoids reuse.
    /// - Returns: The git metadata for the enclosing repository, or
    ///   ``GitWorkspaceMetadata/notARepository`` when there is none.
    public nonisolated func workspaceMetadata(
        for directory: String,
        trackedPathEventGeneration: GitTrackedPathEventGeneration?
    ) async -> GitWorkspaceMetadata {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return .notARepository
        }
        let trackedChanges = await gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
        return GitWorkspaceMetadata(
            isRepository: true,
            branch: Self.gitBranchName(repository: repository),
            isDirty: trackedChanges.isDirty,
            indexSignature: trackedChanges.indexSignature,
            indexContentSignature: trackedChanges.indexContentSignature,
            headSignature: Self.gitHeadSignature(repository: repository)
        )
    }

    nonisolated func gitTrackedChangesSnapshot(
        repository: ResolvedGitRepository,
        trackedPathEventGeneration: GitTrackedPathEventGeneration?
    ) async -> GitTrackedChangesSnapshot {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let trackedPathEventGeneration,
              let indexStatus = fileStatusReader.status(atPath: indexURL.path) else {
            return gitTrackedChangesSnapshot(repository: repository)
        }

        let indexStatSignature = indexStatus.indexStatSignature
        if let snapshot = await trackedChangesSnapshotCache.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: trackedPathEventGeneration
        ) {
            return snapshot
        }

        let snapshot = gitTrackedChangesSnapshot(repository: repository)
        await trackedChangesSnapshotCache.store(
            snapshot,
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
        return snapshot
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
    public nonisolated func watchedPaths(for directory: String) async -> [String]? {
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
