internal import CmuxAgentChat
import Foundation

/// Reads committed, staged, unstaged, and untracked changes for a workspace directory.
///
/// Git subprocesses execute from `nonisolated async` methods, so callers may
/// safely invoke the service from the main actor without blocking it. Tests can
/// inject a ``WorkspaceChangesGitRunning`` seam and a summary cache with a fake
/// clock; production uses `/usr/bin/git` with `GIT_OPTIONAL_LOCKS=0`.
///
/// ```swift
/// let changes = WorkspaceChangesService()
/// let summary = await changes.summary(forDirectory: checkoutPath)
/// ```
public struct WorkspaceChangesService: Sendable {
    let runner: any WorkspaceChangesGitRunning
    let snapshotLoader: WorkspaceChangesSnapshotLoader
    private let summaryCache: WorkspaceChangesSummaryCache
    private let authorizedPathCache: WorkspaceChangesAuthorizedPathCache
    let baseContentCache: WorkspaceChangesBaseContentCache
    let pathValidator = WorkspaceChangesPathValidator()
    let contentReader = WorkspaceChangesContentReader()
    let fingerprintReader: any WorkspaceChangesContentFingerprintReading

    /// Creates a production workspace-changes service.
    public init() {
        let runner = SystemWorkspaceChangesGitRunner()
        self.runner = runner
        snapshotLoader = WorkspaceChangesSnapshotLoader(runner: runner)
        summaryCache = WorkspaceChangesSummaryCache()
        authorizedPathCache = WorkspaceChangesAuthorizedPathCache()
        baseContentCache = WorkspaceChangesBaseContentCache()
        fingerprintReader = WorkspaceChangesContentReader()
    }

    init(
        runner: any WorkspaceChangesGitRunning,
        summaryCache: WorkspaceChangesSummaryCache = WorkspaceChangesSummaryCache(),
        authorizedPathCache: WorkspaceChangesAuthorizedPathCache = WorkspaceChangesAuthorizedPathCache(),
        baseContentCache: WorkspaceChangesBaseContentCache = WorkspaceChangesBaseContentCache(),
        fingerprintReader: any WorkspaceChangesContentFingerprintReading =
            WorkspaceChangesContentReader()
    ) {
        self.runner = runner
        snapshotLoader = WorkspaceChangesSnapshotLoader(runner: runner)
        self.summaryCache = summaryCache
        self.authorizedPathCache = authorizedPathCache
        self.baseContentCache = baseContentCache
        self.fingerprintReader = fingerprintReader
    }

    /// Reads aggregate changes for the repository enclosing `directory`.
    ///
    /// Results are cached for 15 seconds by canonical repository root. A
    /// directory outside a repository, or a Git failure, returns
    /// ``WorkspaceChangesSummary/notARepository``.
    ///
    /// - Parameters:
    ///   - directory: An absolute workspace directory to inspect.
    ///   - force: Whether to bypass the repository-root summary cache.
    /// - Returns: Aggregate committed and working-tree changes.
    public nonisolated func summary(
        forDirectory directory: String,
        force: Bool = false
    ) async -> WorkspaceChangesSummary {
        guard let scope = try? snapshotLoader.resolveScope(forDirectory: directory) else {
            return .notARepository
        }
        if !force,
           let cached = await summaryCache.summary(forRepoRoot: scope.repoRoot) {
            return cached
        }
        guard let snapshot = try? snapshotLoader.loadSnapshot(scope: scope) else {
            return .notARepository
        }
        let summary = WorkspaceChangesSummary(
            isRepository: true,
            repoRoot: scope.repoRoot,
            branch: scope.branch,
            baseRef: scope.baseRef,
            filesChanged: snapshot.totalFileCount,
            additions: snapshot.additions,
            deletions: snapshot.deletions
        )
        await summaryCache.store(summary, forRepoRoot: scope.repoRoot)
        return summary
    }

    /// Reads path-sorted changes for the repository enclosing `directory`.
    ///
    /// The returned file array is capped at 500 entries before untracked-file
    /// inspection. The file count covers the full result; line totals include
    /// all tracked files plus inspected untracked files. A directory outside a
    /// repository returns the not-a-repository sentinel.
    ///
    /// - Parameter directory: An absolute workspace directory to inspect.
    /// - Returns: Changed-file metadata and aggregate totals.
    /// - Throws: ``WorkspaceChangesServiceError/gitFailure`` when Git cannot execute
    ///   or fails while producing a repository snapshot.
    public nonisolated func changedFiles(
        forDirectory directory: String
    ) async throws -> WorkspaceChangedFiles {
        guard let scope = try snapshotLoader.resolveScope(forDirectory: directory) else {
            return .notARepository
        }
        let snapshot = try snapshotLoader.loadSnapshot(scope: scope)
        return changedFilesValue(from: snapshot)
    }

    /// Reads artifact-compatible metadata for an authorized changed file revision.
    ///
    /// The authorization snapshot is reused for 15 seconds so a chunked preview
    /// does not rerun Git status for every request. Base blobs are materialized
    /// once in the bounded temporary-file cache.
    ///
    /// - Parameters:
    ///   - directory: An absolute workspace directory inside the repository.
    ///   - path: The current changed path, or a rename's old path for ``WorkspaceChangesFileRevision/base``.
    ///   - revision: The working-tree or comparison-base revision to inspect.
    /// - Returns: Metadata compatible with the shared artifact viewer.
    /// - Throws: ``WorkspaceChangesServiceError`` when validation, authorization, or reading fails.
    public nonisolated func fileStat(
        forDirectory directory: String,
        path: String,
        revision: WorkspaceChangesFileRevision
    ) async throws -> WorkspaceChangesFileStat {
        let authorizedFile = try await authorizedFile(
            forDirectory: directory,
            path: path,
            revision: revision,
            fetchOffset: nil
        )
        do {
            if let blobSize = authorizedFile.baseBlobSize {
                return try await statBaseFile(
                    authorizedFile,
                    projectedSize: blobSize
                )
            }
            return try contentReader.stat(
                repoRoot: authorizedFile.snapshot.scope.repoRoot,
                relativePath: authorizedFile.relativePath
            )
        } catch ArtifactByteReader.Error.fileNotFound {
            throw WorkspaceChangesServiceError.fileNotFound
        } catch {
            throw WorkspaceChangesServiceError.gitFailure
        }
    }

    /// Reads one bounded byte slice for an authorized changed file revision.
    ///
    /// Current content is sliced directly from the working-tree file. Base
    /// content is sliced from the actor-owned materialization cache, so Git is
    /// invoked at most once per `(repository, base, path)` cache entry.
    ///
    /// - Parameters:
    ///   - directory: An absolute workspace directory inside the repository.
    ///   - path: The current changed path, or a rename's old path for ``WorkspaceChangesFileRevision/base``.
    ///   - revision: The working-tree or comparison-base revision to read.
    ///   - offset: Requested byte offset; values outside the file are clamped.
    ///   - length: Requested byte count, clamped to the artifact transfer limit.
    /// - Returns: One artifact-compatible byte chunk with honest total size and EOF metadata.
    /// - Throws: ``WorkspaceChangesServiceError`` when validation, authorization, or reading fails.
    public nonisolated func fileFetch(
        forDirectory directory: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        offset: Int64,
        length: Int
    ) async throws -> WorkspaceChangesFileChunk {
        let clampedOffset = max(0, offset)
        let authorizedFile = try await authorizedFile(
            forDirectory: directory,
            path: path,
            revision: revision,
            fetchOffset: clampedOffset
        )
        let clampedLength = ChatArtifactTransferPolicy.defaultPolicy.clampedChunkLength(length)
        do {
            if authorizedFile.baseBlobSize != nil {
                return try await fetchBaseFile(
                    authorizedFile,
                    offset: clampedOffset,
                    length: clampedLength
                )
            }
            return try contentReader.fetch(
                repoRoot: authorizedFile.snapshot.scope.repoRoot,
                relativePath: authorizedFile.relativePath,
                offset: clampedOffset,
                length: clampedLength
            )
        } catch ArtifactByteReader.Error.fileNotFound {
            throw WorkspaceChangesServiceError.fileNotFound
        } catch let error as WorkspaceChangesServiceError {
            throw error
        } catch {
            throw WorkspaceChangesServiceError.gitFailure
        }
    }

    private nonisolated func authorizedFile(
        forDirectory directory: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        fetchOffset: Int64?
    ) async throws -> WorkspaceChangesAuthorizedPathCache.AuthorizedFile {
        let cacheKey = WorkspaceChangesAuthorizedPathCache.Key(
            directory: directory,
            path: path,
            revision: revision
        )
        if let fetchOffset,
           let cached = await authorizedPathCache.authorizedFileForFetch(
               key: cacheKey,
               offset: fetchOffset
           ) {
            return cached
        }
        guard let scope = try snapshotLoader.resolveScope(forDirectory: directory) else {
            throw WorkspaceChangesServiceError.notARepository
        }
        let normalizedPath = try pathValidator.validatedPath(path, repoRoot: scope.repoRoot)
        let authorization = try await authorizationSnapshot(scope: scope)
        let authorizedPaths = revision == .current
            ? authorization.currentPaths
            : authorization.basePaths
        guard authorizedPaths.contains(normalizedPath) else {
            throw WorkspaceChangesServiceError.forbidden
        }

        let baseBlobSize: Int64?
        let baseBlobOID: String?
        if revision == .base {
            let runner = self.runner
            let object = "\(scope.diffBaseCommitOID):\(normalizedPath)"
            let repoURL = URL(fileURLWithPath: authorization.scope.repoRoot, isDirectory: true)
            let oidResult = try runner.run(
                arguments: ["--literal-pathspecs", "rev-parse", object],
                in: repoURL
            )
            let oid = String(decoding: oidResult.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard oidResult.exitCode == 0, !oid.isEmpty else {
                throw WorkspaceChangesServiceError.gitFailure
            }
            let sizeResult = try runner.run(
                arguments: ["--literal-pathspecs", "cat-file", "-s", oid],
                in: repoURL
            )
            let sizeText = String(decoding: sizeResult.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard sizeResult.exitCode == 0,
                  let blobSize = Int64(sizeText),
                  await baseContentCache.permitsEntry(size: blobSize) else {
                throw WorkspaceChangesServiceError.gitFailure
            }
            baseBlobSize = blobSize
            baseBlobOID = oid
        } else {
            baseBlobSize = nil
            baseBlobOID = nil
        }
        let authorizedFile = WorkspaceChangesAuthorizedPathCache.AuthorizedFile(
            snapshot: authorization,
            relativePath: normalizedPath,
            baseBlobSize: baseBlobSize,
            baseBlobOID: baseBlobOID
        )
        await authorizedPathCache.store(
            authorizedFile,
            for: cacheKey,
            awaitsInitialFetch: fetchOffset == nil
        )
        return authorizedFile
    }

    private nonisolated func authorizationSnapshot(
        scope: WorkspaceChangesScope
    ) async throws -> WorkspaceChangesAuthorizedPathCache.Snapshot {
        if let cached = await authorizedPathCache.snapshot(
            forRepoRoot: scope.repoRoot,
            baseCommitOID: scope.diffBaseCommitOID
        ) {
            return cached
        }
        let snapshot = try snapshotLoader.loadSnapshot(scope: scope)
        let currentPaths = Set(snapshot.files.map(\.path))
        let basePaths = Set(snapshot.files.flatMap { file in
            if let oldPath = file.oldPath {
                return [file.path, oldPath]
            }
            return [file.path]
        })
        let authorization = WorkspaceChangesAuthorizedPathCache.Snapshot(
            identity: UUID(),
            scope: scope,
            currentPaths: currentPaths,
            basePaths: basePaths
        )
        return authorization
    }

}
