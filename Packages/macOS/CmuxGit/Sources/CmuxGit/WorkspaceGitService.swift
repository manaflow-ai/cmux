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

    /// The maximum number of untracked paths inspected per status response.
    public static let maximumUntrackedEntries = 2_000

    private static let commandTimeout: TimeInterval = 30
    private static let emptyTreeObject = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    private static let untrackedReadByteCap = 4 * 1024 * 1024
    private static let binaryPrefixByteCap = 8 * 1024
    private let commandRunner: any CommandRunning

    /// Creates a workspace Git service.
    /// - Parameter commandRunner: The subprocess runner; tests can inject a fake.
    public init(commandRunner: any CommandRunning = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    /// Reads staged, unstaged, and bounded untracked changes relative to `HEAD`.
    /// - Parameter directory: A workspace working directory inside the repository.
    /// - Returns: The normalized status and line-count summary.
    /// - Throws: ``WorkspaceGitServiceError`` when the directory is not a repository or Git fails.
    public nonisolated func status(forDirectory directory: String) async throws -> WorkspaceGitStatus {
        let repository = try repository(containing: directory)
        let repoRoot = repository.workTreeRoot
        let baselineObject = await hasHead(in: repoRoot) ? "HEAD" : Self.emptyTreeObject
        let porcelain = try await runGit(
            in: repoRoot,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--find-renames"],
            acceptedExitStatuses: [0],
            operation: "status"
        )
        let trackedNumstat = try await runGit(
            in: repoRoot,
            arguments: ["-c", "core.quotepath=off", "diff", baselineObject, "--numstat", "-z", "-M", "--"],
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

        var retainedEntries: [WorkspaceGitPorcelainEntry] = []
        var untrackedStatsByPath: [String: WorkspaceGitNumstatEntry] = [:]
        var untrackedCount = 0
        var truncatedUntracked = false
        for entry in porcelainEntries {
            guard entry.untracked else {
                retainedEntries.append(entry)
                continue
            }
            guard untrackedCount < Self.maximumUntrackedEntries else {
                truncatedUntracked = true
                continue
            }
            untrackedCount += 1
            retainedEntries.append(entry)
            untrackedStatsByPath[entry.path] = Self.untrackedStats(for: entry.path, in: repoRoot)
        }

        let files: [WorkspaceGitStatusFile]
        do {
            files = try parser.parse(
                porcelainEntries: retainedEntries,
                trackedNumstat: trackedNumstat,
                untrackedStatsByPath: untrackedStatsByPath
            )
        } catch {
            throw WorkspaceGitServiceError.commandFailed(operation: "status.parse")
        }
        return WorkspaceGitStatus(
            repoRoot: repoRoot,
            baseline: "worktree",
            files: files,
            totalAdditions: files.reduce(0) { $0 + $1.additions },
            totalDeletions: files.reduce(0) { $0 + $1.deletions },
            truncatedUntracked: truncatedUntracked
        )
    }

    /// Generates per-path unified diffs in request order and enforces a byte cap.
    /// - Parameters:
    ///   - directory: A workspace working directory inside the repository.
    ///   - paths: Safe repository-relative path pairs, in client request order.
    ///   - byteCap: The maximum UTF-8 bytes of concatenated patch content.
    /// - Returns: Included, truncated, and individually oversized path results.
    /// - Throws: ``WorkspaceGitServiceError`` when validation or Git execution fails.
    public nonisolated func diff(
        forDirectory directory: String,
        paths: [WorkspaceGitDiffPath],
        byteCap: Int = WorkspaceGitService.defaultDiffByteCap
    ) async throws -> WorkspaceGitDiff {
        for request in paths {
            guard Self.isValidRepoRelativePath(request.path) else {
                throw WorkspaceGitServiceError.invalidPath(request.path)
            }
            if let oldPath = request.oldPath, !Self.isValidRepoRelativePath(oldPath) {
                throw WorkspaceGitServiceError.invalidPath(oldPath)
            }
        }
        let repository = try repository(containing: directory)
        let repoRoot = repository.workTreeRoot
        let baselineObject = await hasHead(in: repoRoot) ? "HEAD" : Self.emptyTreeObject
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

        for (index, request) in paths.enumerated() {
            let patch = try await patch(
                for: request,
                baselineObject: baselineObject,
                untracked: untrackedPaths.contains(request.path),
                in: repoRoot
            )
            guard accumulator.append(path: request.path, patch: patch) else {
                accumulator.appendTruncated(contentsOf: paths.dropFirst(index + 1).map(\.path))
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

    private nonisolated func patch(
        for request: WorkspaceGitDiffPath,
        baselineObject: String,
        untracked: Bool,
        in repoRoot: String
    ) async throws -> String {
        if untracked {
            return try await runGit(
                in: repoRoot,
                arguments: [
                    "-c", "core.quotepath=off", "diff", "--no-index", "--no-color", "--",
                    "/dev/null", request.path,
                ],
                acceptedExitStatuses: [0, 1],
                operation: "diff.untracked"
            )
        }
        var pathspecs: [String] = []
        if let oldPath = request.oldPath {
            pathspecs.append(oldPath)
        }
        pathspecs.append(request.path)
        return try await runGit(
            in: repoRoot,
            arguments: [
                "-c", "core.quotepath=off", "diff", baselineObject,
                "--no-ext-diff", "--no-color", "-M", "--",
            ] + pathspecs,
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
            executable: "/usr/bin/env",
            arguments: ["GIT_OPTIONAL_LOCKS=0", "git"] + arguments,
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

    private nonisolated func hasHead(in directory: String) async -> Bool {
        let result = await commandRunner.run(
            directory: directory,
            executable: "/usr/bin/env",
            arguments: ["GIT_OPTIONAL_LOCKS=0", "git", "rev-parse", "--verify", "HEAD"],
            timeout: Self.commandTimeout
        )
        return result.executionError == nil && !result.timedOut && result.exitStatus == 0
    }

    /// Reads at most four MiB per untracked file. Counts are intentionally
    /// bounded approximations for larger files; unreadable paths stay visible
    /// with zero counts instead of failing the complete status response.
    private static func untrackedStats(for path: String, in repoRoot: String) -> WorkspaceGitNumstatEntry {
        let url = URL(fileURLWithPath: repoRoot, isDirectory: true).appendingPathComponent(path)
        do {
            // lstat gate: opening a FIFO/socket/device blocks or misbehaves, and a
            // symlink's git content is its target path, not the target's bytes.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular else {
                return WorkspaceGitNumstatEntry(
                    path: path,
                    oldPath: nil,
                    additions: 0,
                    deletions: 0,
                    binary: false
                )
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: untrackedReadByteCap) ?? Data()
            let binary = data.prefix(binaryPrefixByteCap).contains(0)
            let additions = binary ? 0 : data.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            return WorkspaceGitNumstatEntry(
                path: path,
                oldPath: nil,
                additions: additions,
                deletions: 0,
                binary: binary
            )
        } catch {
            return WorkspaceGitNumstatEntry(
                path: path,
                oldPath: nil,
                additions: 0,
                deletions: 0,
                binary: false
            )
        }
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
