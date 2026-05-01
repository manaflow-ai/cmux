import Foundation

/// Pure-Swift wrapper around `git worktree` operations used by the per-pane
/// isolation feature (issue #3414, dmux-style).
///
/// Phase 1 surface: `add`, `list`, `remove`, `snapshot`, `repoToplevel`, plus
/// the `parseListPorcelain` helper exposed for tests. UI / sidebar / pane
/// lifecycle hooks live in later phases — see
/// `docs/per-pane-worktree-isolation.md`.
public enum WorktreeManager {
    // MARK: - Types

    public struct Record: Equatable {
        public let path: String
        public let head: String?
        public let branch: String?
        public let isDetached: Bool
        public let isBare: Bool
        public let isLocked: Bool
        public let isPrunable: Bool

        public init(
            path: String,
            head: String? = nil,
            branch: String? = nil,
            isDetached: Bool = false,
            isBare: Bool = false,
            isLocked: Bool = false,
            isPrunable: Bool = false
        ) {
            self.path = path
            self.head = head
            self.branch = branch
            self.isDetached = isDetached
            self.isBare = isBare
            self.isLocked = isLocked
            self.isPrunable = isPrunable
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case gitNotFound(executable: String)
        case notARepository(path: String)
        case worktreePathExists(path: String)
        case branchAlreadyExists(branch: String)
        case worktreeNotFound(path: String)
        case gitFailed(args: [String], stderr: String, exitCode: Int32)
        case malformedOutput(reason: String)

        public var description: String {
            switch self {
            case .gitNotFound(let exe):
                return "git executable not found at \(exe)"
            case .notARepository(let path):
                return "not a git repository: \(path)"
            case .worktreePathExists(let path):
                return "worktree path already exists: \(path)"
            case .branchAlreadyExists(let branch):
                return "branch already exists: \(branch)"
            case .worktreeNotFound(let path):
                return "no worktree registered at: \(path)"
            case .gitFailed(let args, let stderr, let code):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "git \(args.joined(separator: " ")) failed (exit \(code)): \(trimmed)"
            case .malformedOutput(let reason):
                return "malformed git output: \(reason)"
            }
        }
    }

    // MARK: - Configuration

    /// Path to the `git` executable. Overridable for tests / sandbox builds.
    public static var gitExecutablePath: String = "/usr/bin/git"

    // MARK: - Public API

    /// Resolve the toplevel of the git repository containing `path`. Returns
    /// the absolute path with no trailing newline.
    public static func repoToplevel(forPath path: String) throws -> String {
        let stdout = try runGit(args: ["rev-parse", "--show-toplevel"], cwd: path)
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Failure.notARepository(path: path)
        }
        return trimmed
    }

    /// Create a new worktree at `worktreePath` checked out on `branch`,
    /// branched off `basedOn` (default: current HEAD of `repoPath`).
    ///
    /// Mirrors `git worktree add -b <branch> <path> <basedOn>`.
    @discardableResult
    public static func add(
        repoPath: String,
        worktreePath: String,
        branch: String,
        basedOn: String? = nil
    ) throws -> Record {
        if FileManager.default.fileExists(atPath: worktreePath) {
            throw Failure.worktreePathExists(path: worktreePath)
        }
        // git worktree add will refuse if branch exists; surface a typed error.
        if branchExists(repoPath: repoPath, branch: branch) {
            throw Failure.branchAlreadyExists(branch: branch)
        }
        var args: [String] = ["worktree", "add", "-b", branch, worktreePath]
        if let basedOn { args.append(basedOn) }
        _ = try runGit(args: args, cwd: repoPath)

        return Record(
            path: absolute(worktreePath),
            head: try? runGit(args: ["rev-parse", "HEAD"], cwd: worktreePath)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            branch: branch,
            isDetached: false,
            isBare: false,
            isLocked: false,
            isPrunable: false
        )
    }

    /// Enumerate all worktrees registered for the repository at `repoPath`.
    public static func list(repoPath: String) throws -> [Record] {
        let output = try runGit(args: ["worktree", "list", "--porcelain"], cwd: repoPath)
        return parseListPorcelain(output)
    }

    /// Remove a worktree. `force: true` discards uncommitted changes.
    public static func remove(
        repoPath: String,
        worktreePath: String,
        force: Bool = false
    ) throws {
        var args: [String] = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        do {
            _ = try runGit(args: args, cwd: repoPath)
        } catch let Failure.gitFailed(_, stderr, _) where stderr.contains("is not a working tree") {
            throw Failure.worktreeNotFound(path: worktreePath)
        }
    }

    /// Capture the worktree's current state as a recovery branch ref in the
    /// main repository so the branch survives `remove`. Returns the commit
    /// the branch points at.
    ///
    /// If the working tree has uncommitted (tracked) changes, those are
    /// captured via `git stash create` and the snapshot branch points at the
    /// stash commit (which has HEAD as its parent). Untracked files are not
    /// captured in Phase 1 — see `docs/per-pane-worktree-isolation.md`.
    @discardableResult
    public static func snapshot(
        worktreePath: String,
        mainRepoPath: String,
        snapshotBranch: String
    ) throws -> String {
        let stashRaw = (try? runGit(args: ["stash", "create"], cwd: worktreePath)) ?? ""
        let stash = stashRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: String
        if !stash.isEmpty {
            target = stash
        } else {
            target = try runGit(args: ["rev-parse", "HEAD"], cwd: worktreePath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if branchExists(repoPath: mainRepoPath, branch: snapshotBranch) {
            throw Failure.branchAlreadyExists(branch: snapshotBranch)
        }
        _ = try runGit(args: ["branch", snapshotBranch, target], cwd: mainRepoPath)
        return target
    }

    // MARK: - Parsing (exposed for tests)

    /// Parse `git worktree list --porcelain` output into typed records.
    ///
    /// Format (one block per worktree, blank-line separated):
    ///   worktree <path>
    ///   HEAD <sha>
    ///   branch refs/heads/<name>   (or `detached`, optionally `bare`, `locked`, `prunable`)
    public static func parseListPorcelain(_ output: String) -> [Record] {
        var records: [Record] = []
        var path: String?
        var head: String?
        var branch: String?
        var detached = false
        var bare = false
        var locked = false
        var prunable = false

        func flush() {
            if let path {
                records.append(
                    Record(
                        path: path,
                        head: head,
                        branch: branch,
                        isDetached: detached,
                        isBare: bare,
                        isLocked: locked,
                        isPrunable: prunable
                    )
                )
            }
            path = nil
            head = nil
            branch = nil
            detached = false
            bare = false
            locked = false
            prunable = false
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            if let value = stripPrefix(line, "worktree ") {
                // Boundary between blocks without a blank line shouldn't happen,
                // but be defensive.
                if path != nil { flush() }
                path = value
            } else if let value = stripPrefix(line, "HEAD ") {
                head = value
            } else if let value = stripPrefix(line, "branch ") {
                let prefix = "refs/heads/"
                branch = value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
            } else if line == "detached" {
                detached = true
            } else if line == "bare" {
                bare = true
            } else if line.hasPrefix("locked") {
                locked = true
            } else if line.hasPrefix("prunable") {
                prunable = true
            }
        }
        flush()
        return records
    }

    // MARK: - Internals

    private static func stripPrefix(_ line: String, _ prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func branchExists(repoPath: String, branch: String) -> Bool {
        do {
            _ = try runGit(
                args: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
                cwd: repoPath
            )
            return true
        } catch {
            return false
        }
    }

    private static func absolute(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.path
    }

    /// Run `git <args>` in `cwd`. Returns stdout on success; throws
    /// `Failure.gitFailed` with stderr captured on non-zero exit.
    @discardableResult
    static func runGit(args: [String], cwd: String) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: gitExecutablePath) else {
            throw Failure.gitNotFound(executable: gitExecutablePath)
        }

        return try autoreleasepool {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdoutRead = stdoutPipe.fileHandleForReading
            let stdoutWrite = stdoutPipe.fileHandleForWriting
            let stderrRead = stderrPipe.fileHandleForReading
            let stderrWrite = stderrPipe.fileHandleForWriting

            process.executableURL = URL(fileURLWithPath: gitExecutablePath)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            defer {
                try? stdoutRead.close()
                try? stdoutWrite.close()
                try? stderrRead.close()
                try? stderrWrite.close()
            }

            do {
                try process.run()
            } catch {
                throw Failure.gitFailed(args: args, stderr: "\(error)", exitCode: -1)
            }

            // See PortScanner.captureStandardOutput — must close parent's write
            // handle before draining the pipe to avoid blocking on EOF.
            try? stdoutWrite.close()
            try? stderrWrite.close()
            let stdoutData = stdoutRead.readDataToEndOfFile()
            let stderrData = stderrRead.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                let lower = stderr.lowercased()
                if lower.contains("not a git repository") {
                    throw Failure.notARepository(path: cwd)
                }
                throw Failure.gitFailed(
                    args: args,
                    stderr: stderr,
                    exitCode: process.terminationStatus
                )
            }
            return stdout
        }
    }
}
