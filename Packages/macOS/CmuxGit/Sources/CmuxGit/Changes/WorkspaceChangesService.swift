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
    private struct Scope: Sendable {
        let repoRoot: String
        let branch: String?
        let baseRef: String?
        let diffBase: String
    }

    private struct Snapshot: Sendable {
        let scope: Scope
        let files: [WorkspaceChangedFile]
    }

    private static let maximumFileCount = 500

    private let runner: any WorkspaceChangesGitRunning
    private let summaryCache: WorkspaceChangesSummaryCache
    private let parser = WorkspaceChangesParser()
    private let pathValidator = WorkspaceChangesPathValidator()
    private let diffTruncator = WorkspaceDiffTruncator()

    /// Creates a production workspace-changes service.
    public init() {
        runner = SystemWorkspaceChangesGitRunner()
        summaryCache = WorkspaceChangesSummaryCache()
    }

    init(
        runner: any WorkspaceChangesGitRunning,
        summaryCache: WorkspaceChangesSummaryCache = WorkspaceChangesSummaryCache()
    ) {
        self.runner = runner
        self.summaryCache = summaryCache
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
        guard let scope = resolveScope(forDirectory: directory) else {
            return .notARepository
        }
        if let cached = await summaryCache.summary(forRepoRoot: scope.repoRoot) {
            return cached
        }
        guard let snapshot = loadSnapshot(scope: scope) else {
            return .notARepository
        }
        let summary = WorkspaceChangesSummary(
            isRepository: true,
            repoRoot: scope.repoRoot,
            branch: scope.branch,
            baseRef: scope.baseRef,
            filesChanged: snapshot.files.count,
            additions: snapshot.files.reduce(0) { $0 + $1.additions },
            deletions: snapshot.files.reduce(0) { $0 + $1.deletions }
        )
        await summaryCache.store(summary, forRepoRoot: scope.repoRoot)
        return summary
    }

    /// Reads path-sorted changes for the repository enclosing `directory`.
    ///
    /// The returned file array is capped at 500 entries while totals describe
    /// the full result. Git failures use the same not-a-repository sentinel as
    /// directories outside a repository.
    ///
    /// - Parameter directory: An absolute workspace directory to inspect.
    /// - Returns: Changed-file metadata and aggregate totals.
    public nonisolated func changedFiles(forDirectory directory: String) async -> WorkspaceChangedFiles {
        guard let scope = resolveScope(forDirectory: directory),
              let snapshot = loadSnapshot(scope: scope) else {
            return .notARepository
        }
        return changedFilesValue(from: snapshot)
    }

    /// Reads a bounded unified diff for one changed repository-relative path.
    ///
    /// Absolute paths and paths that escape the repository root lexically or
    /// through symlinks are rejected before the path reaches Git. Output is
    /// capped at 400 KiB or 6,000 lines at a complete-hunk boundary.
    ///
    /// - Parameters:
    ///   - directory: An absolute workspace directory to inspect.
    ///   - path: A repository-relative path from the current changes snapshot.
    /// - Returns: The file's metadata and bounded unified diff.
    /// - Throws: ``WorkspaceChangesServiceError`` when validation or Git fails.
    public nonisolated func fileDiff(
        forDirectory directory: String,
        path: String
    ) async throws -> WorkspaceFileDiff {
        guard let scope = resolveScope(forDirectory: directory) else {
            throw WorkspaceChangesServiceError.notARepository
        }
        let normalizedPath = try pathValidator.validatedPath(path, repoRoot: scope.repoRoot)
        guard let snapshot = loadSnapshot(scope: scope) else {
            throw WorkspaceChangesServiceError.gitFailure
        }
        guard let file = snapshot.files.first(where: { $0.path == normalizedPath }) else {
            throw WorkspaceChangesServiceError.fileNotChanged
        }
        if file.isBinary {
            return fileDiffValue(file: file, unifiedDiff: "", truncated: false)
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
        guard let result = run(arguments, repoRoot: scope.repoRoot),
              acceptedExitCodes.contains(result.exitCode) else {
            throw WorkspaceChangesServiceError.gitFailure
        }
        let bounded = diffTruncator.truncate(String(decoding: result.output, as: UTF8.self))
        return fileDiffValue(file: file, unifiedDiff: bounded.text, truncated: bounded.truncated)
    }

    /// Pins the SE-0338 executor-hop contract that keeps Git off the caller's actor.
    nonisolated func executionHopsOffCallersThread() async -> Bool {
        pthread_main_np() == 0
    }

    private nonisolated func resolveScope(forDirectory directory: String) -> Scope? {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard let rootResult = try? runner.run(
            arguments: ["rev-parse", "--show-toplevel"],
            in: directoryURL
        ), rootResult.exitCode == 0 else { return nil }
        let repoRoot = String(decoding: rootResult.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoRoot.isEmpty else { return nil }

        let branch = output(
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            repoRoot: repoRoot,
            acceptedExitCodes: [0, 1]
        )
        let defaultRef = resolveDefaultBranch(repoRoot: repoRoot)
        guard let branch,
              let defaultRef,
              branch != defaultRef,
              defaultRef != "origin/\(branch)",
              let mergeBase = output(
                  arguments: ["merge-base", "HEAD", defaultRef],
                  repoRoot: repoRoot,
                  acceptedExitCodes: [0]
              ) else {
            return Scope(repoRoot: repoRoot, branch: branch, baseRef: nil, diffBase: "HEAD")
        }
        return Scope(repoRoot: repoRoot, branch: branch, baseRef: defaultRef, diffBase: mergeBase)
    }

    private nonisolated func resolveDefaultBranch(repoRoot: String) -> String? {
        if let symbolic = output(
            arguments: ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            repoRoot: repoRoot,
            acceptedExitCodes: [0, 1]
        ) {
            return symbolic
        }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            guard let result = run(
                ["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"],
                repoRoot: repoRoot
            ) else { return nil }
            if result.exitCode == 0 { return candidate }
        }
        return nil
    }

    private nonisolated func loadSnapshot(scope: Scope) -> Snapshot? {
        guard let statusResult = run(
            ["diff", "-M", "--name-status", "-z", scope.diffBase, "--"],
            repoRoot: scope.repoRoot
        ), statusResult.exitCode == 0,
        let numstatResult = run(
            ["diff", "-M", "--numstat", "-z", scope.diffBase, "--"],
            repoRoot: scope.repoRoot
        ), numstatResult.exitCode == 0,
        let untrackedResult = run(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            repoRoot: scope.repoRoot
        ), untrackedResult.exitCode == 0 else { return nil }

        let statsByPath = Dictionary(
            uniqueKeysWithValues: parser.numstatEntries(from: numstatResult.output).map { ($0.path, $0) }
        )
        var files = parser.nameStatusEntries(from: statusResult.output).map { entry in
            let stat = statsByPath[entry.path]
            return WorkspaceChangedFile(
                path: entry.path,
                oldPath: entry.oldPath,
                status: entry.status,
                additions: stat?.additions ?? 0,
                deletions: stat?.deletions ?? 0,
                isBinary: stat?.isBinary ?? false
            )
        }
        for path in parser.untrackedPaths(from: untrackedResult.output) {
            guard let result = run(
                ["diff", "--numstat", "--no-index", "--", "/dev/null", path],
                repoRoot: scope.repoRoot
            ), result.exitCode == 0 || result.exitCode == 1,
            let stat = parser.singleNumstatEntry(from: result.output, path: path) else { return nil }
            files.append(WorkspaceChangedFile(
                path: path,
                oldPath: nil,
                status: .untracked,
                additions: stat.additions,
                deletions: stat.deletions,
                isBinary: stat.isBinary
            ))
        }
        return Snapshot(scope: scope, files: files.sorted { $0.path < $1.path })
    }

    private nonisolated func changedFilesValue(from snapshot: Snapshot) -> WorkspaceChangedFiles {
        WorkspaceChangedFiles(
            isRepository: true,
            repoRoot: snapshot.scope.repoRoot,
            branch: snapshot.scope.branch,
            baseRef: snapshot.scope.baseRef,
            files: Array(snapshot.files.prefix(Self.maximumFileCount)),
            filesChanged: snapshot.files.count,
            additions: snapshot.files.reduce(0) { $0 + $1.additions },
            deletions: snapshot.files.reduce(0) { $0 + $1.deletions },
            truncated: snapshot.files.count > Self.maximumFileCount
        )
    }

    private nonisolated func fileDiffValue(
        file: WorkspaceChangedFile,
        unifiedDiff: String,
        truncated: Bool
    ) -> WorkspaceFileDiff {
        WorkspaceFileDiff(
            path: file.path,
            oldPath: file.oldPath,
            status: file.status,
            isBinary: file.isBinary,
            additions: file.additions,
            deletions: file.deletions,
            unifiedDiff: unifiedDiff,
            truncated: truncated
        )
    }

    private nonisolated func output(
        arguments: [String],
        repoRoot: String,
        acceptedExitCodes: Set<Int32>
    ) -> String? {
        guard let result = run(arguments, repoRoot: repoRoot),
              acceptedExitCodes.contains(result.exitCode) else { return nil }
        let trimmed = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated func run(
        _ arguments: [String],
        repoRoot: String
    ) -> WorkspaceChangesGitResult? {
        try? runner.run(arguments: arguments, in: URL(fileURLWithPath: repoRoot, isDirectory: true))
    }
}
