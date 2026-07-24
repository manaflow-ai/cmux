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
    private let runner: any WorkspaceChangesGitRunning
    private let snapshotLoader: WorkspaceChangesSnapshotLoader
    private let summaryCache: WorkspaceChangesSummaryCache
    private let authorizedPathCache: WorkspaceChangesAuthorizedPathCache
    private let baseContentCache: WorkspaceChangesBaseContentCache
    private let pathValidator = WorkspaceChangesPathValidator()
    private let contentReader = WorkspaceChangesContentReader()

    /// Creates a production workspace-changes service.
    public init() {
        let runner = SystemWorkspaceChangesGitRunner()
        self.runner = runner
        snapshotLoader = WorkspaceChangesSnapshotLoader(runner: runner)
        summaryCache = WorkspaceChangesSummaryCache()
        authorizedPathCache = WorkspaceChangesAuthorizedPathCache()
        baseContentCache = WorkspaceChangesBaseContentCache()
    }

    init(
        runner: any WorkspaceChangesGitRunning,
        summaryCache: WorkspaceChangesSummaryCache = WorkspaceChangesSummaryCache(),
        authorizedPathCache: WorkspaceChangesAuthorizedPathCache = WorkspaceChangesAuthorizedPathCache(),
        baseContentCache: WorkspaceChangesBaseContentCache = WorkspaceChangesBaseContentCache()
    ) {
        self.runner = runner
        snapshotLoader = WorkspaceChangesSnapshotLoader(runner: runner)
        self.summaryCache = summaryCache
        self.authorizedPathCache = authorizedPathCache
        self.baseContentCache = baseContentCache
    }

    /// Reads aggregate changes for the repository enclosing `directory`.
    ///
    /// Results are cached for 15 seconds by canonical repository root. A
    /// directory outside a repository, or a Git failure, returns
    /// ``WorkspaceChangesSummary/notARepository``.
    ///
    /// - Parameter directory: An absolute workspace directory to inspect.
    /// - Returns: Aggregate committed and working-tree changes.
    public nonisolated func summary(forDirectory directory: String) async -> WorkspaceChangesSummary {
        guard let scope = snapshotLoader.resolveScope(forDirectory: directory) else {
            return .notARepository
        }
        if let cached = await summaryCache.summary(forRepoRoot: scope.repoRoot) {
            return cached
        }
        guard let snapshot = snapshotLoader.loadSnapshot(scope: scope) else {
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
    /// all tracked files plus inspected untracked files. Git failures use the
    /// same not-a-repository sentinel as directories outside a repository.
    ///
    /// - Parameter directory: An absolute workspace directory to inspect.
    /// - Returns: Changed-file metadata and aggregate totals.
    public nonisolated func changedFiles(forDirectory directory: String) async -> WorkspaceChangedFiles {
        guard let scope = snapshotLoader.resolveScope(forDirectory: directory),
              let snapshot = snapshotLoader.loadSnapshot(scope: scope) else {
            return .notARepository
        }
        return changedFilesValue(from: snapshot)
    }

    /// Reads a progressively bounded unified diff for one changed repository-relative path.
    ///
    /// Absolute paths and paths that escape the repository root lexically or
    /// through symlinks are rejected before the path reaches Git. Output is
    /// capped at 400 KiB or 6,000 lines at a complete-hunk boundary by
    /// default. A requested line budget scales the byte budget proportionally,
    /// up to the 1,000,000-line guard and 6 MiB response budget.
    ///
    /// - Parameters:
    ///   - directory: An absolute workspace directory to inspect.
    ///   - path: A repository-relative path from the current changes snapshot.
    ///   - maxLines: Optional progressive line budget. Values are clamped to
    ///     the default minimum and response abuse guard.
    /// - Returns: The file's metadata and bounded unified diff.
    /// - Throws: ``WorkspaceChangesServiceError`` when validation or Git fails.
    public nonisolated func fileDiff(
        forDirectory directory: String,
        path: String,
        maxLines: Int? = nil
    ) async throws -> WorkspaceFileDiff {
        guard let scope = snapshotLoader.resolveScope(forDirectory: directory) else {
            throw WorkspaceChangesServiceError.notARepository
        }
        let normalizedPath = try pathValidator.validatedPath(path, repoRoot: scope.repoRoot)
        guard let snapshot = snapshotLoader.loadSnapshot(scope: scope) else {
            throw WorkspaceChangesServiceError.gitFailure
        }
        guard let file = snapshot.files.first(where: { $0.path == normalizedPath }) else {
            throw WorkspaceChangesServiceError.fileNotChanged
        }
        if file.isBinary {
            return fileDiffValue(
                file: file,
                unifiedDiff: "",
                truncated: false,
                totalLineCount: 0,
                contentFingerprint: currentContentFingerprint(
                    repoRoot: scope.repoRoot,
                    path: normalizedPath
                )
            )
        }

        let arguments: [String]
        let acceptedExitCodes: Set<Int32>
        if file.status == .untracked {
            arguments = ["diff", "--unified=3", "--no-index", "--", "/dev/null", normalizedPath]
            acceptedExitCodes = [0, 1]
        } else {
            arguments = ["diff", "-M", "--unified=3", scope.diffBase, "--", normalizedPath]
            acceptedExitCodes = [0]
        }
        let fingerprintBefore = currentContentFingerprint(
            repoRoot: scope.repoRoot,
            path: normalizedPath
        )
        let truncator = WorkspaceDiffTruncator(requestedMaximumLines: maxLines)
        guard let result = run(
            arguments,
            repoRoot: scope.repoRoot,
            maximumOutputByteCount: truncator.maximumInputBytes
        ), acceptedExitCodes.contains(result.exitCode) || result.standardOutputWasTruncated else {
            throw WorkspaceChangesServiceError.gitFailure
        }
        let fingerprintAfter = currentContentFingerprint(
            repoRoot: scope.repoRoot,
            path: normalizedPath
        )
        let bounded = truncator.truncate(String(decoding: result.output, as: UTF8.self))
        return fileDiffValue(
            file: file,
            unifiedDiff: bounded.text,
            truncated: bounded.truncated || result.standardOutputWasTruncated,
            totalLineCount: result.standardOutputWasTruncated ? nil : bounded.totalLineCount,
            contentFingerprint: contentReader.fileDiffFingerprint(
                before: fingerprintBefore,
                after: fingerprintAfter
            )
        )
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
        let location = try await authorizedFileLocation(
            forDirectory: directory,
            path: path,
            revision: revision,
            fetchOffset: nil
        )
        do {
            return try contentReader.stat(
                repoRoot: location.repoRoot,
                relativePath: location.relativePath
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
        let location = try await authorizedFileLocation(
            forDirectory: directory,
            path: path,
            revision: revision,
            fetchOffset: max(0, offset)
        )
        let clampedLength = ChatArtifactTransferPolicy.defaultPolicy.clampedChunkLength(length)
        do {
            return try contentReader.fetch(
                repoRoot: location.repoRoot,
                relativePath: location.relativePath,
                offset: max(0, offset),
                length: clampedLength
            )
        } catch ArtifactByteReader.Error.fileNotFound {
            throw WorkspaceChangesServiceError.fileNotFound
        } catch {
            throw WorkspaceChangesServiceError.gitFailure
        }
    }

    private nonisolated func authorizedFileLocation(
        forDirectory directory: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        fetchOffset: Int64?
    ) async throws -> (repoRoot: String, relativePath: String) {
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
            return try await materializedLocation(for: cached)
        }
        guard let scope = snapshotLoader.resolveScope(forDirectory: directory) else {
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
        if revision == .base {
            let runner = self.runner
            let object = "\(scope.diffBaseCommitOID):\(normalizedPath)"
            let repoURL = URL(fileURLWithPath: authorization.scope.repoRoot, isDirectory: true)
            let sizeResult = try runner.run(
                arguments: ["cat-file", "-s", object],
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
        } else {
            baseBlobSize = nil
        }
        let authorizedFile = WorkspaceChangesAuthorizedPathCache.AuthorizedFile(
            snapshot: authorization,
            relativePath: normalizedPath,
            baseBlobSize: baseBlobSize
        )
        await authorizedPathCache.store(
            authorizedFile,
            for: cacheKey,
            awaitsInitialFetch: fetchOffset == nil
        )
        return try await materializedLocation(for: authorizedFile)
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
        guard let snapshot = snapshotLoader.loadSnapshot(scope: scope) else {
            throw WorkspaceChangesServiceError.gitFailure
        }
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

    private nonisolated func materializedLocation(
        for authorizedFile: WorkspaceChangesAuthorizedPathCache.AuthorizedFile
    ) async throws -> (repoRoot: String, relativePath: String) {
        let scope = authorizedFile.snapshot.scope
        guard let blobSize = authorizedFile.baseBlobSize else {
            return (scope.repoRoot, authorizedFile.relativePath)
        }
        let key = WorkspaceChangesBaseContentCache.Key(
            repoRoot: scope.repoRoot,
            baseCommitOID: scope.diffBaseCommitOID,
            path: authorizedFile.relativePath
        )
        let runner = self.runner
        let object = "\(scope.diffBaseCommitOID):\(authorizedFile.relativePath)"
        let repoURL = URL(fileURLWithPath: scope.repoRoot, isDirectory: true)
        let fileURL = try await baseContentCache.fileURL(for: key) { destination in
            let result = try runner.run(
                arguments: ["show", object],
                in: repoURL,
                writingOutputTo: destination,
                maximumOutputByteCount: blobSize
            )
            guard result.exitCode == 0,
                  !result.standardOutputWasTruncated else {
                throw WorkspaceChangesServiceError.fileNotFound
            }
            return blobSize
        }
        return (fileURL.deletingLastPathComponent().path, fileURL.lastPathComponent)
    }

    private nonisolated func currentContentFingerprint(
        repoRoot: String,
        path: String
    ) -> String? {
        contentReader.contentFingerprint(repoRoot: repoRoot, relativePath: path)
    }

    private nonisolated func run(
        _ arguments: [String],
        repoRoot: String,
        maximumOutputByteCount: Int
    ) -> WorkspaceChangesGitResult? {
        try? runner.run(
            arguments: arguments,
            in: URL(fileURLWithPath: repoRoot, isDirectory: true),
            maximumOutputByteCount: maximumOutputByteCount
        )
    }
}
