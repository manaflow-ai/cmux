import Foundation
import Dispatch

/// Reads a directory's git metadata from the on-disk repository, with bounded
/// Git fallbacks for non-files reference storage and unsafe index scans.
///
/// This service does the filesystem work that powers the workspace sidebar's
/// branch label, dirty indicator, and pull-request badge: resolving the
/// enclosing repository, resolving refs, parsing `index`/`config`, and deriving the set
/// of paths a filesystem watcher should observe to know when that metadata
/// becomes stale.
///
/// It is a `Sendable` value facade over filesystem reads plus a small
/// actor-isolated tracked-change cache. Its async API leaves the caller's actor,
/// and the bounded direct-stat/fallback-process portion hops again to a dedicated
/// concurrent utility queue so blocking I/O never pins Swift's cooperative
/// executor. Reads for independent repositories can still run in parallel. The
/// cache is only consulted through the watcher-generation API; direct reads
/// without a watcher generation always do a conservative check.
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
    let dirtyStatusReader: any GitDirtyStatusReading
    /// Resolves the checked-out ref without exposing storage details to callers.
    let referenceReader: any GitReferenceReading
    let degradationRecorder: GitMetadataDegradationRecorder
    let safetyConfiguration: GitMetadataSafetyConfiguration
    let referenceSnapshotLimiter: GitReferenceSnapshotLimiter
    private let trackedChangesSnapshotCache: GitTrackedChangesSnapshotCache

    /// Creates a git-metadata service.
    public init() {
        let safetyConfiguration = GitMetadataSafetyConfiguration()
        self.fileStatusReader = SystemGitFileStatusReader()
        self.dirtyStatusReader = SystemGitDirtyStatusReader(
            boundedCommandWallTimeLimit: safetyConfiguration.gitStatusWallTime
        )
        self.referenceReader = SystemGitReferenceReader(
            boundedCommandWallTimeLimit: safetyConfiguration.gitStatusWallTime
        )
        self.degradationRecorder = GitMetadataDegradationRecorder(
            gitStatusWallTime: safetyConfiguration.gitStatusWallTime
        )
        self.safetyConfiguration = safetyConfiguration
        self.trackedChangesSnapshotCache = GitTrackedChangesSnapshotCache()
        self.referenceSnapshotLimiter = GitReferenceSnapshotLimiter()
    }

    init(
        fileStatusReader: any GitFileStatusReading,
        dirtyStatusReader: (any GitDirtyStatusReading)? = nil,
        referenceReader: (any GitReferenceReading)? = nil,
        degradationRecorder: GitMetadataDegradationRecorder? = nil,
        safetyConfiguration: GitMetadataSafetyConfiguration = GitMetadataSafetyConfiguration(),
        trackedChangesSnapshotCache: GitTrackedChangesSnapshotCache = GitTrackedChangesSnapshotCache(),
        referenceSnapshotLimiter: GitReferenceSnapshotLimiter = GitReferenceSnapshotLimiter()
    ) {
        self.fileStatusReader = fileStatusReader
        self.dirtyStatusReader = dirtyStatusReader ?? SystemGitDirtyStatusReader(
            boundedCommandWallTimeLimit: safetyConfiguration.gitStatusWallTime
        )
        self.referenceReader = referenceReader ?? SystemGitReferenceReader(
            boundedCommandWallTimeLimit: safetyConfiguration.gitStatusWallTime
        )
        self.degradationRecorder = degradationRecorder ?? GitMetadataDegradationRecorder(
            gitStatusWallTime: safetyConfiguration.gitStatusWallTime
        )
        self.safetyConfiguration = safetyConfiguration
        self.trackedChangesSnapshotCache = trackedChangesSnapshotCache
        self.referenceSnapshotLimiter = referenceSnapshotLimiter
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
        let initialReferences = await gitReferenceSnapshot(repository: repository)
        var trackedChanges = await gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
        // HEAD and index updates are separate filesystem operations. Re-read
        // HEAD after the index scan and discard a generation-cached result when
        // the checkout moved during this observation window.
        let resolvedReferences = await gitReferenceSnapshot(repository: repository)
        if resolvedReferences.headSignature != initialReferences.headSignature {
            trackedChanges = await gitTrackedChangesSnapshot(repository: repository)
        }
        return GitWorkspaceMetadata(
            isRepository: true,
            branch: resolvedReferences.branchName,
            isDirty: trackedChanges.isDirty,
            indexSignature: trackedChanges.indexSignature,
            indexContentSignature: trackedChanges.indexContentSignature,
            headSignature: resolvedReferences.headSignature
        )
    }

    nonisolated func gitTrackedChangesSnapshot(
        repository: ResolvedGitRepository,
        trackedPathEventGeneration: GitTrackedPathEventGeneration?
    ) async -> GitTrackedChangesSnapshot {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let trackedPathEventGeneration,
              let indexStatus = fileStatusReader.status(atPath: indexURL.path) else {
            return await gitTrackedChangesSnapshot(repository: repository)
        }

        let indexStatSignature = indexStatus.indexStatSignature
        if let snapshot = await trackedChangesSnapshotCache.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: trackedPathEventGeneration
        ) {
            return snapshot
        }

        let snapshot = await gitTrackedChangesSnapshot(repository: repository)
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
    ///   outside a repository. Incomplete branch-aware plans retain conservative
    ///   root metadata paths so a later event can trigger a retry.
    @concurrent
    public nonisolated func watchedPaths(for directory: String) async -> [String]? {
        await watchDescriptor(for: directory)?.watchedPaths
    }

    /// The complete Git-aware event plan for `directory`, including tracked
    /// path filtering and any large-repository degradation decision.
    @concurrent
    public nonisolated func watchDescriptor(
        for directory: String
    ) async -> GitWorkspaceMetadataWatchDescriptor? {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return nil
        }
        let watchInputs = await branchAwareConfigPathsByRepository(
            repository: repository,
            safetyConfiguration: safetyConfiguration
        )
        guard let descriptor = Self.workspaceGitMetadataWatchDescriptor(
            for: directory,
            safetyConfiguration: safetyConfiguration,
            configPathsByRepository: watchInputs.configPathsByRepository,
            indexSnapshotsByRepository: watchInputs.indexSnapshotsByRepository
        ) else {
            return nil
        }
        return applyingForcedWorkTreeRoots(
            descriptor,
            repositories: watchInputs.forceWorkTreeRootRepositories
        )
    }

    /// The GitHub repository slugs (`owner/name`) configured as remotes for the
    /// repository enclosing `directory`.
    ///
    /// Reads remote URLs straight from `config`, following `include`/`includeIf`
    /// with the same resolved branch context as Git. Orders the result
    /// `upstream`, then `origin`, then the rest, de-duplicated.
    ///
    /// - Parameter directory: An absolute path to inspect.
    /// - Returns: Ordered, de-duplicated GitHub slugs; empty when there is no
    ///   repository or no GitHub remote.
    @concurrent
    public nonisolated func repositorySlugs(forDirectory directory: String) async -> [String] {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return []
        }
        let deadline = DispatchTime.now()
            + max(5, safetyConfiguration.gitStatusWallTime * 8)
        let branchContext = await gitReferenceBranchContext(
            repository: repository,
            deadline: deadline
        )
        let traversal = GitConfigBranchTraversal(
            repository: repository,
            branchContext: branchContext,
            deadline: deadline
        )
        let traversalResult = traversal.remoteVResult()
        let output: String?
        if traversalResult.isComplete {
            output = traversalResult.output
        } else if traversalResult.isUnsafe {
            output = nil
        } else {
            output = await gitRemoteVFallback(repository: repository, deadline: deadline)
        }
        guard let output else { return [] }
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
        let references = await gitReferenceSnapshot(repository: repository)
        return references.checkedOutBranch
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
