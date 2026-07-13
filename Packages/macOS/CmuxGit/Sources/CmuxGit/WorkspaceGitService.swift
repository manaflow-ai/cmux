public import CmuxFoundation
import Foundation

/// Reads workspace status and size-bounded unified diffs through system Git.
///
/// The service reuses ``GitMetadataService``'s repository resolver, runs Git
/// through an injected ``CommandRunning`` seam, and keeps NUL-delimited parsing
/// plus diff cap enforcement in pure package types.
///
/// ```swift
/// let git = WorkspaceGitService()
/// let status = try await git.status(forDirectory: "/path/to/worktree")
/// ```
public struct WorkspaceGitService: Sendable {
    /// The soft response cap used by mobile diff calls: four mebibytes.
    public static let defaultDiffByteCap = 4 * 1024 * 1024

    private static let commandTimeout: TimeInterval = 30
    private let commandRunner: any CommandRunning

    /// Creates a workspace Git service.
    /// - Parameter commandRunner: The subprocess runner; tests can inject a fake.
    public init(commandRunner: any CommandRunning = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    /// Reads all staged, unstaged, and untracked changes relative to `HEAD`.
    /// - Parameter directory: A workspace working directory inside the repository.
    /// - Returns: The normalized status and line-count summary.
    /// - Throws: ``WorkspaceGitServiceError`` when the directory is not a repository or Git fails.
    public nonisolated func status(forDirectory directory: String) async throws -> WorkspaceGitStatus {
        let repository = try repository(containing: directory)
        let repoRoot = repository.workTreeRoot
        let porcelain = try await runGit(
            in: repoRoot,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--find-renames"],
            acceptedExitStatuses: [0],
            operation: "status"
        )
        let trackedNumstat = try await runGit(
            in: repoRoot,
            arguments: ["diff", "HEAD", "--numstat", "-z", "-M", "--"],
            acceptedExitStatuses: [0],
            operation: "status.numstat"
        )

        let parser = WorkspaceGitStatusParser()
        let porcelainEntries: [WorkspaceGitPorcelainEntry]
        do {
            porcelainEntries = try parser.parsePorcelain(porcelain)
        } catch {
            throw WorkspaceGitServiceError.commandFailed(operation: "status.parse")
        }

        var untrackedNumstatByPath: [String: String] = [:]
        for entry in porcelainEntries where entry.untracked {
            untrackedNumstatByPath[entry.path] = try await runGit(
                in: repoRoot,
                arguments: ["diff", "--no-index", "--numstat", "--no-color", "--", "/dev/null", entry.path],
                acceptedExitStatuses: [0, 1],
                operation: "status.untracked_numstat"
            )
        }

        let files: [WorkspaceGitStatusFile]
        do {
            files = try parser.parse(
                porcelain: porcelain,
                trackedNumstat: trackedNumstat,
                untrackedNumstatByPath: untrackedNumstatByPath
            )
        } catch {
            throw WorkspaceGitServiceError.commandFailed(operation: "status.parse")
        }
        return WorkspaceGitStatus(
            repoRoot: repoRoot,
            baseline: "worktree",
            files: files,
            totalAdditions: files.reduce(0) { $0 + $1.additions },
            totalDeletions: files.reduce(0) { $0 + $1.deletions }
        )
    }

    /// Generates per-path unified diffs in request order and enforces a byte cap.
    /// - Parameters:
    ///   - directory: A workspace working directory inside the repository.
    ///   - paths: Safe repository-relative paths, in client request order.
    ///   - byteCap: The maximum UTF-8 bytes of concatenated patch content.
    /// - Returns: Included, truncated, and individually oversized path results.
    /// - Throws: ``WorkspaceGitServiceError`` when validation or Git execution fails.
    public nonisolated func diff(
        forDirectory directory: String,
        paths: [String],
        byteCap: Int = WorkspaceGitService.defaultDiffByteCap
    ) async throws -> WorkspaceGitDiff {
        for path in paths where !Self.isValidRepoRelativePath(path) {
            throw WorkspaceGitServiceError.invalidPath(path)
        }
        let repository = try repository(containing: directory)
        let repoRoot = repository.workTreeRoot
        let porcelain = try await runGit(
            in: repoRoot,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--find-renames"],
            acceptedExitStatuses: [0],
            operation: "diff.status"
        )
        let untrackedPaths: Set<String>
        do {
            untrackedPaths = Set(
                try WorkspaceGitStatusParser().parsePorcelain(porcelain)
                    .filter(\.untracked)
                    .map(\.path)
            )
        } catch {
            throw WorkspaceGitServiceError.commandFailed(operation: "diff.status_parse")
        }
        var accumulator = WorkspaceGitDiffAccumulator(byteCap: byteCap)

        for (index, path) in paths.enumerated() {
            let patch = try await patch(for: path, untracked: untrackedPaths.contains(path), in: repoRoot)
            guard accumulator.append(path: path, patch: patch) else {
                accumulator.appendTruncated(contentsOf: paths.dropFirst(index + 1))
                break
            }
        }
        return accumulator.response()
    }

    private nonisolated func repository(containing directory: String) throws -> ResolvedGitRepository {
        guard let repository = GitMetadataService.resolveGitRepository(containing: directory) else {
            throw WorkspaceGitServiceError.notRepository
        }
        return repository
    }

    private nonisolated func patch(for path: String, untracked: Bool, in repoRoot: String) async throws -> String {
        if untracked {
            return try await runGit(
                in: repoRoot,
                arguments: ["diff", "--no-index", "--no-color", "--", "/dev/null", path],
                acceptedExitStatuses: [0, 1],
                operation: "diff.untracked"
            )
        }
        return try await runGit(
            in: repoRoot,
            arguments: ["diff", "HEAD", "--no-ext-diff", "--no-color", "-M", "--", path],
            acceptedExitStatuses: [0],
            operation: "diff.tracked"
        )
    }

    private nonisolated func runGit(
        in directory: String,
        arguments: [String],
        acceptedExitStatuses: Set<Int32>,
        operation: String
    ) async throws -> String {
        let result = await commandRunner.run(
            directory: directory,
            executable: "git",
            arguments: arguments,
            timeout: Self.commandTimeout
        )
        guard result.executionError == nil,
              !result.timedOut,
              let exitStatus = result.exitStatus,
              acceptedExitStatuses.contains(exitStatus),
              let stdout = result.stdout else {
            throw WorkspaceGitServiceError.commandFailed(operation: operation)
        }
        return stdout
    }

    private static func isValidRepoRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
