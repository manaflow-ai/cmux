public import CmuxFoundation
import Foundation

/// Computes read-only, cursor-paged working-tree diffs for cmux clients.
///
/// Git execution is injected through ``CommandRunning``. Production callers use
/// ``CommandRunner`` while tests can provide deterministic failures or inspect
/// the exact hardened Git arguments.
public struct CmuxDiffEngine: Sendable {
    private let commandRunner: any CommandRunning
    private let rowLimit: Int

    /// Creates a diff engine.
    /// - Parameters:
    ///   - commandRunner: The injected Git process runner.
    ///   - rowLimit: The maximum number of parsed rows returned in one file page.
    public init(
        commandRunner: any CommandRunning = CommandRunner(),
        rowLimit: Int = 2_000
    ) {
        self.commandRunner = commandRunner
        self.rowLimit = max(rowLimit, 1)
    }

    /// Computes repository totals and per-file metadata for a working tree.
    /// - Parameters:
    ///   - repositoryPath: A repository root or a directory inside its worktree.
    ///   - baseSpec: The requested comparison baseline.
    ///   - ignoreWhitespace: Whether Git should ignore whitespace changes with `-w`.
    /// - Returns: The resolved baseline, totals, and all changed files.
    /// - Throws: ``DiffEngineError`` when the repository or baseline cannot be resolved.
    public nonisolated func summary(
        repositoryPath: String,
        baseSpec: DiffBaseSpec,
        ignoreWhitespace: Bool
    ) async throws -> DiffSummary {
        let context = try await context(repositoryPath: repositoryPath, baseSpec: baseSpec)
        let snapshot = try await GitDiffSnapshotLoader(
            commands: context.commands,
            repositoryRoot: context.repositoryRoot
        ).load(base: context.base, ignoreWhitespace: ignoreWhitespace)
        let files = snapshot.files.map(\.summary)
        return DiffSummary(
            baseInfo: snapshot.base.info,
            totals: DiffTotals(
                files: files.count,
                additions: files.reduce(0) { $0 + $1.additions },
                deletions: files.reduce(0) { $0 + $1.deletions }
            ),
            files: files,
            truncatedFileCount: 0
        )
    }

    /// Parses and pages the patch for one changed file.
    /// - Parameters:
    ///   - repositoryPath: A repository root or a directory inside its worktree.
    ///   - path: The new-side repository-relative path.
    ///   - oldPath: The old-side path for a rename or copy; both paths are passed as Git pathspecs.
    ///   - baseSpec: The requested comparison baseline.
    ///   - ignoreWhitespace: Whether Git should ignore whitespace changes with `-w`.
    ///   - cursor: A row offset returned by a previous page.
    ///   - force: Whether to parse a file marked large instead of returning the load gate.
    /// - Returns: Parsed hunks, binary/large state, and an optional next cursor.
    /// - Throws: ``DiffEngineError`` when the repository, path, baseline, or cursor is invalid.
    public nonisolated func fileHunks(
        repositoryPath: String,
        path: String,
        oldPath: String? = nil,
        baseSpec: DiffBaseSpec,
        ignoreWhitespace: Bool,
        cursor: Int? = nil,
        force: Bool = false
    ) async throws -> DiffFilePage {
        guard cursor == nil || cursor! >= 0 else { throw DiffEngineError.invalidRange }
        let context = try await context(repositoryPath: repositoryPath, baseSpec: baseSpec)
        let reader = WorkingTreeFileReader(repositoryRoot: context.repositoryRoot)
        _ = try reader.regularFileData(path: path)
        let pathspecs = Array(Set([oldPath, path].compactMap { $0 })).sorted()
        let snapshot = try await GitDiffSnapshotLoader(
            commands: context.commands,
            repositoryRoot: context.repositoryRoot
        ).load(base: context.base, ignoreWhitespace: ignoreWhitespace, pathspecs: pathspecs)
        guard let file = snapshot.files.first(where: {
            $0.summary.path == path && (oldPath == nil || $0.summary.oldPath == oldPath)
        }) else {
            throw DiffEngineError.fileNotFound(path)
        }
        if file.summary.isBinary {
            return DiffFilePage(hunks: [], isBinary: true, tooLarge: false, nextCursor: nil)
        }
        if file.summary.isLarge, !force {
            return DiffFilePage(hunks: [], isBinary: false, tooLarge: true, nextCursor: nil)
        }
        let hunks = UnifiedDiffParser().parse(file.patch)
        return try DiffPageBuilder(rowLimit: rowLimit).page(hunks: hunks, cursor: cursor)
    }

    /// Reads a one-based inclusive new-side context range from the worktree.
    ///
    /// When the path is deleted, this falls back to the path's `HEAD` blob.
    /// - Parameters:
    ///   - repositoryPath: A repository root or a directory inside its worktree.
    ///   - path: The repository-relative path.
    ///   - startLine: The first one-based line to return.
    ///   - endLine: The last one-based line to return.
    /// - Returns: The requested text lines, clipped at end of file.
    /// - Throws: ``DiffEngineError`` when the repository, path, or range is invalid.
    public nonisolated func contextRows(
        repositoryPath: String,
        path: String,
        startLine: Int,
        endLine: Int
    ) async throws -> [String] {
        guard startLine >= 1, endLine >= startLine else {
            throw DiffEngineError.invalidRange
        }
        let initial = GitCommandExecutor(repositoryDirectory: repositoryPath, commandRunner: commandRunner)
        let repositoryRoot = try await initial.repositoryRoot()
        let reader = WorkingTreeFileReader(repositoryRoot: repositoryRoot)
        if let data = try reader.regularFileData(path: path) {
            return reader.selectedLines(data: data, startLine: startLine, endLine: endLine)
        }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw DiffEngineError.invalidPath(path)
        }
        let commands = GitCommandExecutor(repositoryDirectory: repositoryRoot, commandRunner: commandRunner)
        guard let blob = try await commands.run(["cat-file", "blob", "HEAD:./\(path)"], allowFailure: true) else {
            throw DiffEngineError.fileNotFound(path)
        }
        return reader.selectedLines(data: Data(blob.utf8), startLine: startLine, endLine: endLine)
    }

    private nonisolated func context(
        repositoryPath: String,
        baseSpec: DiffBaseSpec
    ) async throws -> (repositoryRoot: String, commands: GitCommandExecutor, base: ResolvedDiffBase) {
        let initial = GitCommandExecutor(repositoryDirectory: repositoryPath, commandRunner: commandRunner)
        let repositoryRoot = try await initial.repositoryRoot()
        let commands = GitCommandExecutor(repositoryDirectory: repositoryRoot, commandRunner: commandRunner)
        return (repositoryRoot, commands, try await resolveBase(baseSpec, commands: commands))
    }

    private nonisolated func resolveBase(
        _ spec: DiffBaseSpec,
        commands: GitCommandExecutor
    ) async throws -> ResolvedDiffBase {
        switch spec.kind {
        case .workingTree:
            if let head = try await verifiedObject("HEAD^{commit}", commands: commands) {
                return ResolvedDiffBase(
                    info: DiffBaseInfo(kind: .workingTree, resolvedRef: head, describe: "HEAD"),
                    object: head
                )
            }
            let emptyTree = try await requiredTrimmed(["hash-object", "-t", "tree", "/dev/null"], commands: commands)
            return ResolvedDiffBase(
                info: DiffBaseInfo(kind: .workingTree, resolvedRef: emptyTree, describe: emptyTree),
                object: emptyTree
            )
        case .lastTurn:
            guard let value = normalized(spec.value),
                  let resolved = try await verifiedObject(value, commands: commands) else {
                throw DiffEngineError.baselineUnavailable
            }
            return ResolvedDiffBase(
                info: DiffBaseInfo(kind: .lastTurn, resolvedRef: resolved, describe: resolved),
                object: resolved
            )
        case .branchBase:
            guard let head = try await verifiedObject("HEAD^{commit}", commands: commands) else {
                let emptyTree = try await requiredTrimmed(["hash-object", "-t", "tree", "/dev/null"], commands: commands)
                return ResolvedDiffBase(
                    info: DiffBaseInfo(kind: .branchBase, resolvedRef: emptyTree, describe: emptyTree),
                    object: emptyTree
                )
            }
            let branch = try await resolveDefaultBranch(override: spec.value, commands: commands)
            let mergeBase = try await requiredTrimmed(["merge-base", head, branch], commands: commands)
            return ResolvedDiffBase(
                info: DiffBaseInfo(kind: .branchBase, resolvedRef: mergeBase, describe: "merge-base(\(branch))"),
                object: mergeBase
            )
        }
    }

    private nonisolated func resolveDefaultBranch(
        override: String?,
        commands: GitCommandExecutor
    ) async throws -> String {
        if let override = normalized(override), try await verifiedObject(override, commands: commands) != nil {
            return override
        }
        if let symbolic = try await commands.run(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            allowFailure: true
        ).flatMap(normalized), try await verifiedObject(symbolic, commands: commands) != nil {
            return symbolic
        }
        for candidate in ["main", "master", "origin/main", "origin/master"] {
            if try await verifiedObject(candidate, commands: commands) != nil {
                return candidate
            }
        }
        throw DiffEngineError.defaultBranchUnavailable
    }

    private nonisolated func verifiedObject(
        _ object: String,
        commands: GitCommandExecutor
    ) async throws -> String? {
        try await commands.run(["rev-parse", "--verify", object], allowFailure: true).flatMap(normalized)
    }

    private nonisolated func requiredTrimmed(
        _ arguments: [String],
        commands: GitCommandExecutor
    ) async throws -> String {
        guard let value = try await commands.run(arguments).flatMap(normalized) else {
            throw DiffEngineError.commandFailed(arguments: arguments, diagnostic: "Git returned no object identifier")
        }
        return value
    }

    private nonisolated func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
