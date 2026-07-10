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
/// It is a `Sendable` value facade over blocking filesystem reads plus an
/// injectable actor-isolated tracked-change scope. Callers that share the scope
/// also share repository refresh authority, completed snapshots, and one
/// in-flight scan per cache key. The
/// reads do blocking filesystem work
/// (walking to the repository, parsing the git `index`/`config`), and are plain
/// `nonisolated async` methods (a struct's `async` methods are nonisolated): a
/// `nonisolated async` function runs on the global concurrent executor, not the
/// caller's actor (SE-0338), so `await git.workspaceMetadata(...)` from the main
/// actor offloads the work off the main thread *and* lets reads for independent
/// repositories run in parallel. The scope is an actor because it is mutable
/// shared state, but it is only consulted through an explicit watcher-event or
/// fallback-round request; direct reads always do a conservative scan.
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
    private let trackedChangesSnapshotScope: GitTrackedChangesSnapshotScope

    /// Creates a git-metadata service with an injectable process scope.
    ///
    /// Services coordinate tracked scans only when they receive the same scope.
    /// The default creates an isolated bounded scope.
    public init(
        trackedChangesSnapshotScope: GitTrackedChangesSnapshotScope = GitTrackedChangesSnapshotScope()
    ) {
        self.fileStatusReader = SystemGitFileStatusReader()
        self.trackedChangesSnapshotScope = trackedChangesSnapshotScope
    }

    init(
        fileStatusReader: any GitFileStatusReading,
        trackedChangesSnapshotScope: GitTrackedChangesSnapshotScope = GitTrackedChangesSnapshotScope()
    ) {
        self.fileStatusReader = fileStatusReader
        self.trackedChangesSnapshotScope = trackedChangesSnapshotScope
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
        await workspaceMetadata(for: directory, snapshotRequest: nil)
    }

    /// Reads a point-in-time snapshot with process-coordinated cache authority.
    public nonisolated func workspaceMetadata(
        for directory: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitWorkspaceMetadata {
        await workspaceMetadataSnapshot(
            for: directory,
            snapshotRequest: snapshotRequest
        ).metadata
    }

    /// Reads metadata and reports whether its stamped authority stayed current.
    public nonisolated func workspaceMetadataSnapshot(
        for directory: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitWorkspaceMetadataSnapshot {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return GitWorkspaceMetadataSnapshot(
                metadata: .notARepository,
                isCurrent: true
            )
        }
        guard let trackedChangesRead = await gitTrackedChangesSnapshotRead(
            repository: repository,
            snapshotRequest: snapshotRequest
        ) else {
            return GitWorkspaceMetadataSnapshot(
                metadata: .notARepository,
                isCurrent: false
            )
        }
        return GitWorkspaceMetadataSnapshot(
            metadata: GitWorkspaceMetadata(
                isRepository: true,
                branch: Self.gitBranchName(repository: repository),
                isDirty: trackedChangesRead.snapshot.isDirty,
                indexSignature: trackedChangesRead.snapshot.indexSignature,
                indexContentSignature: trackedChangesRead.snapshot.indexContentSignature,
                headSignature: Self.gitHeadSignature(repository: repository)
            ),
            isCurrent: trackedChangesRead.isCurrent
        )
    }

    nonisolated func gitTrackedChangesSnapshot(
        repository: ResolvedGitRepository,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitTrackedChangesSnapshot {
        if let read = await gitTrackedChangesSnapshotRead(
            repository: repository,
            snapshotRequest: snapshotRequest
        ) {
            return read.snapshot
        }
        return GitTrackedChangesSnapshot(
            isDirty: false,
            indexSignature: nil,
            indexContentSignature: nil
        )
    }

    nonisolated func gitTrackedChangesSnapshotRead(
        repository: ResolvedGitRepository,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitTrackedChangesSnapshotRead? {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let authority = snapshotRequest?.authority else {
            return GitTrackedChangesSnapshotRead(
                snapshot: gitTrackedChangesSnapshot(repository: repository),
                isCurrent: true
            )
        }
        guard let indexStatus = fileStatusReader.status(atPath: indexURL.path) else {
            let snapshot = gitTrackedChangesSnapshot(repository: repository)
            return await trackedChangesSnapshotScope.validate(
                snapshot: snapshot,
                repository: repository,
                authority: authority
            )
        }

        let indexStatSignature = indexStatus.indexStatSignature
        return await trackedChangesSnapshotScope.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority
        ) {
            gitTrackedChangesSnapshot(repository: repository)
        }
    }

    /// Resolves a directory to the stable identity used by snapshot authority.
    public nonisolated func trackedChangesRepositoryIdentity(
        for directory: String
    ) async -> GitTrackedChangesRepositoryIdentity? {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return nil
        }
        return GitTrackedChangesRepositoryIdentity(repository: repository)
    }

    /// Stamps the scope's current repository revision for one fallback round.
    public nonisolated func trackedChangesSnapshotAuthority(
        for repositoryIdentity: GitTrackedChangesRepositoryIdentity,
        fallbackRoundID: GitFallbackRoundID?
    ) async -> GitTrackedChangesSnapshotAuthority {
        await trackedChangesSnapshotScope.authority(
            for: repositoryIdentity,
            fallbackRoundID: fallbackRoundID
        )
    }

    /// Advances shared repository revision before watcher work is scheduled.
    public nonisolated func recordTrackedPathEvent(
        for repositoryIdentity: GitTrackedChangesRepositoryIdentity,
        sourceEvent: GitTrackedPathEventSource = .unknown
    ) async -> GitTrackedChangesSnapshotAuthority {
        await trackedChangesSnapshotScope.recordWatcherEvent(
            for: repositoryIdentity,
            source: sourceEvent
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

    /// Reads the checked-out branch state for the repository enclosing
    /// `directory`.
    ///
    /// Distinguishes a detached (or non-branch) checkout from a repository
    /// whose `HEAD` is missing or malformed, so callers can treat the latter
    /// as unverified rather than trusting a stale projection.
    ///
    /// - Parameter directory: An absolute path to inspect.
    /// - Returns: The ``GitCheckedOutBranch`` for the enclosing repository, or
    ///   ``GitCheckedOutBranch/notARepository`` when there is none.
    public nonisolated func checkedOutBranch(forDirectory directory: String) async -> GitCheckedOutBranch {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return .notARepository
        }
        return Self.gitCheckedOutBranch(repository: repository)
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
