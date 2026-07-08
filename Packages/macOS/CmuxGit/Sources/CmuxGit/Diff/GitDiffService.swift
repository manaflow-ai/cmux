import CmuxFoundation
public import Foundation

/// Runs git commands needed by the mobile diff-review flow.
public struct GitDiffService: Sendable {
    private static let nonLockingGitEnvironmentKey = "GIT_OPTIONAL_LOCKS"
    private static let nonLockingGitEnvironmentValue = "0"

    private let gitExecutableURL: URL
    private let environment: [String: String]
    private let processDeadlineSeconds: Double

    /// Creates a git diff service.
    ///
    /// - Parameters:
    ///   - gitExecutableURL: Git executable URL.
    ///   - environment: Base process environment.
    ///   - processDeadlineSeconds: Wall-clock bound on each git subprocess.
    ///     The mobile RPC timeout cancels only the awaiting task, never the
    ///     spawned process, so a stalled git (fsmonitor hang, dead network
    ///     filesystem) is terminated here instead of accumulating across
    ///     phone retries.
    public init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processDeadlineSeconds: Double = 20
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.environment = environment
        self.processDeadlineSeconds = processDeadlineSeconds
    }

    /// Resolves the enclosing repository root for a directory.
    ///
    /// - Parameter directory: Directory inside a git repository.
    /// - Returns: Repository root, or `nil` when `directory` is not in a repo.
    public func repositoryRoot(for directory: String) -> String? {
        guard let root = runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"]).successOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !root.isEmpty else { return nil }
        return root
    }

    /// Lists changed files relative to `HEAD`, including untracked files.
    ///
    /// - Parameters:
    ///   - repoRoot: Repository root.
    ///   - maxOutputBytes: Per-listing bound on git output. When a listing
    ///     reaches the bound its subprocess is terminated, the trailing
    ///     partial record is dropped, and the result is marked truncated, so
    ///     a workspace with an enormous change set (for example a large
    ///     unignored generated tree) cannot make one status call accumulate
    ///     unbounded memory.
    /// - Returns: Changed-file summaries in path order, with a truncation marker.
    public func changedFiles(repoRoot: String, maxOutputBytes: Int? = nil) -> GitChangedFiles {
        let numstat = runGit(
            in: repoRoot,
            arguments: ["diff", "HEAD", "--numstat", "-z", "--no-color", "--find-renames"],
            maxOutputBytes: maxOutputBytes
        )
        let nameStatus = runGit(
            in: repoRoot,
            arguments: ["diff", "HEAD", "--name-status", "-z", "--no-color", "--find-renames"],
            maxOutputBytes: maxOutputBytes
        )
        let untracked = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            maxOutputBytes: maxOutputBytes
        )
        let files = parseChangedFiles(
            numstatOutput: completeRecords(numstat),
            nameStatusOutput: completeRecords(nameStatus),
            untrackedOutput: completeRecords(untracked)
        )
        return GitChangedFiles(
            files: files,
            truncated: numstat.capped || nameStatus.capped || untracked.capped
        )
    }

    /// Drops the trailing partial NUL-separated record a byte cap can leave
    /// behind, so capped listings only contribute complete records.
    private func completeRecords(_ result: GitProcessResult) -> String? {
        guard let output = result.successOutput else { return nil }
        guard result.capped else { return output }
        guard let lastNul = output.lastIndex(of: "\0") else { return "" }
        return String(output[...lastNul])
    }

    /// Reads a unified diff for one repository-relative file path.
    ///
    /// - Parameters:
    ///   - repoRoot: Repository root.
    ///   - path: Repository-relative path.
    ///   - maxOutputBytes: Upper bound on diff bytes read from git. When the
    ///     output reaches this bound the git process is terminated and the
    ///     bounded prefix (trimmed to a UTF-8 boundary) is returned, so a huge
    ///     diff never accumulates unbounded memory. Callers that cap responses
    ///     should pass their cap plus a small margin so the returned text still
    ///     exceeds the cap and their truncation detection fires.
    /// - Returns: Raw one-file unified diff, or `nil` when git fails.
    public func fileDiff(repoRoot: String, path: String, maxOutputBytes: Int? = nil) -> GitFileDiff? {
        // Validate on a trimmed copy only; the pathspec passed to git must stay
        // byte-exact because repository paths may legitimately start or end
        // with whitespace (`changedFiles` reports them verbatim).
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Single-file API: a directory-shaped request ("." or a subdirectory)
        // would expand as a leading-directory pathspec into a combined
        // multi-file diff, bypassing the changed-file selection the response
        // is modeled around. Deleted files no longer exist on disk, so this
        // only rejects paths that currently resolve to a directory.
        var isDirectory: ObjCBool = false
        let absolutePath = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(path).path
        if FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return nil
        }
        if isUntracked(repoRoot: repoRoot, path: path, maxOutputBytes: maxOutputBytes) {
            let result = runGit(
                in: repoRoot,
                arguments: ["diff", "--no-index", "--no-color", "--", "/dev/null", path],
                acceptedTerminationStatuses: [0, 1],
                maxOutputBytes: maxOutputBytes
            )
            guard let output = result.successOutput else { return nil }
            return GitFileDiff(path: path, unifiedDiff: output)
        }
        let result = runGit(
            in: repoRoot,
            arguments: ["diff", "HEAD", "--no-color", "--find-renames", "--", Self.literalPathspec(path)],
            maxOutputBytes: maxOutputBytes
        )
        guard let output = result.successOutput else { return nil }
        return GitFileDiff(path: path, unifiedDiff: output)
    }

    /// Wraps a repository path in `:(literal)` pathspec magic so glob
    /// characters in real filenames (`*`, `?`, `[`) match the file byte-exact
    /// instead of expanding as a wildcard pattern over the whole tree.
    private static func literalPathspec(_ path: String) -> String {
        ":(literal)\(path)"
    }

    func parseChangedFiles(numstatOutput: String?, nameStatusOutput: String?, untrackedOutput: String?) -> [GitDiffSummary] {
        var partials: [String: GitDiffSummaryPartial] = [:]
        parseNumstatOutput(numstatOutput, into: &partials)
        parseNameStatusOutput(nameStatusOutput, into: &partials)
        parseUntrackedOutput(untrackedOutput, into: &partials)
        return partials.values
            .map(\.summary)
            .sorted { lhs, rhs in lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending }
    }

    private func parseNumstatOutput(_ output: String?, into partials: inout [String: GitDiffSummaryPartial]) {
        guard let output, !output.isEmpty else { return }
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let numstat = GitDiffNumstatToken(token: token, tokens: tokens, index: &index) {
                partials[numstat.path, default: GitDiffSummaryPartial(path: numstat.path)]
                    .apply(additions: numstat.additions, deletions: numstat.deletions, oldPath: numstat.oldPath)
                continue
            }
            index += 1
        }
    }

    private func parseNameStatusOutput(_ output: String?, into partials: inout [String: GitDiffSummaryPartial]) {
        guard let output, !output.isEmpty else { return }
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let status = GitDiffNameStatusToken(token: token, tokens: tokens, index: &index) {
                partials[status.path, default: GitDiffSummaryPartial(path: status.path)]
                    .apply(status: status.status, oldPath: status.oldPath)
                continue
            }
            index += 1
        }
    }

    private func parseUntrackedOutput(_ output: String?, into partials: inout [String: GitDiffSummaryPartial]) {
        guard let output, !output.isEmpty else { return }
        let paths = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        for path in paths where partials[path] == nil {
            partials[path] = GitDiffSummaryPartial(path: path, status: .untracked)
        }
    }

    /// Whether `path` is an untracked file. The `:(literal)` pathspec keeps a
    /// glob-looking request (`*`, `?`, `[`) from expanding over the whole
    /// untracked tree, and the byte bound caps the listing a directory-shaped
    /// request can still emit (a directory can never equal itself in the
    /// output, so a capped listing only ever fails closed to "tracked").
    private func isUntracked(repoRoot: String, path: String, maxOutputBytes: Int? = nil) -> Bool {
        let output = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z", "--", Self.literalPathspec(path)],
            maxOutputBytes: maxOutputBytes
        ).successOutput
        return output?.split(separator: "\0", omittingEmptySubsequences: true).contains(Substring(path)) == true
    }

    private func runGit(
        in directory: String,
        arguments: [String],
        acceptedTerminationStatuses: Set<Int32> = [0],
        maxOutputBytes: Int? = nil
    ) -> GitProcessResult {
        // A cancelled surrounding task (e.g. a timed-out mobile RPC whose
        // cancellation is forwarded into the detached git work) must not
        // spawn further subprocesses; outside any task this reads false.
        guard !Task.isCancelled else {
            return GitProcessResult(output: nil)
        }
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = nonLockingGitEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Wall-clock watchdog: terminate git at the deadline so a stalled
            // subprocess never outlives the request that spawned it. The
            // cancellable timer source is the sanctioned bounded-delay shape
            // here (no async context exists for a Clock sleep, and the read
            // below blocks this thread).
            let watchdog = GitProcessWatchdog(process: process)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + processDeadlineSeconds)
            timer.setEventHandler { watchdog.fire() }
            timer.activate()
            defer { timer.cancel() }
            let read = Self.readOutput(
                pipe.fileHandleForReading,
                maxOutputBytes: maxOutputBytes,
                process: process
            )
            process.waitUntilExit()
            if read.capped || watchdog.didFire {
                // We terminated git ourselves (output bound or deadline); its
                // exit status reflects our signal, not a git failure. Return
                // the bounded partial output and mark it cut off.
                return GitProcessResult(
                    output: Self.decodeUTF8DroppingPartialTail(read.data),
                    capped: true
                )
            }
            guard acceptedTerminationStatuses.contains(process.terminationStatus) else {
                return GitProcessResult(output: nil)
            }
            return GitProcessResult(output: String(data: read.data, encoding: .utf8))
        } catch {
            return GitProcessResult(output: nil)
        }
    }

    /// Drains process stdout, stopping (and terminating the process) once
    /// `maxOutputBytes` is reached so a huge diff never accumulates unbounded
    /// memory before response-level capping.
    private static func readOutput(
        _ handle: FileHandle,
        maxOutputBytes: Int?,
        process: Process
    ) -> (data: Data, capped: Bool) {
        guard let maxOutputBytes else {
            return (handle.readDataToEndOfFileOrEmpty(), false)
        }
        var data = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty else {
                return (data, false)
            }
            data.append(chunk)
            if data.count >= maxOutputBytes {
                process.terminate()
                try? handle.close()
                return (Data(data.prefix(maxOutputBytes)), true)
            }
        }
    }

    /// Decodes capped output, dropping at most one trailing partial UTF-8
    /// scalar introduced by the byte-bounded cut.
    private static func decodeUTF8DroppingPartialTail(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        var trimmed = data
        for _ in 0..<3 {
            guard !trimmed.isEmpty else { break }
            trimmed.removeLast()
            if let text = String(data: trimmed, encoding: .utf8) { return text }
        }
        return nil
    }

    /// Ambient git repository-selection variables that would make a
    /// subprocess ignore `currentDirectoryURL` and resolve/diff a DIFFERENT
    /// repository than the selected workspace (e.g. cmux launched from a
    /// shell or hook with `GIT_DIR` exported). The mobile UI trusts these
    /// responses as the workspace's diff, so the service scrubs them.
    private static let scrubbedGitEnvironmentKeys: Set<String> = [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_NAMESPACE",
        "GIT_PREFIX",
        "GIT_CEILING_DIRECTORIES",
    ]

    private func nonLockingGitEnvironment() -> [String: String] {
        var environment = environment
        for key in Self.scrubbedGitEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment[Self.nonLockingGitEnvironmentKey] = Self.nonLockingGitEnvironmentValue
        return environment
    }
}

/// Deadline watchdog for one running git process. `@unchecked Sendable`:
/// the flag is lock-guarded and `Process.terminate()` is a thread-safe
/// `kill(2)` wrapper once the process has launched.
private final class GitProcessWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func fire() {
        lock.lock()
        fired = true
        lock.unlock()
        process.terminate()
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

private struct GitProcessResult {
    let output: String?
    /// Whether the output was cut off at the caller's byte bound.
    let capped: Bool

    init(output: String?, capped: Bool = false) {
        self.output = output
        self.capped = capped
    }

    var successOutput: String? {
        output
    }
}

private struct GitDiffSummaryPartial {
    let path: String
    var oldPath: String?
    var status: GitDiffStatus?
    var additions: Int?
    var deletions: Int?

    init(path: String, oldPath: String? = nil, status: GitDiffStatus? = nil, additions: Int? = nil, deletions: Int? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }

    var summary: GitDiffSummary {
        GitDiffSummary(
            path: path,
            oldPath: oldPath,
            status: status ?? .modified,
            additions: additions,
            deletions: deletions
        )
    }

    mutating func apply(additions: Int?, deletions: Int?, oldPath: String?) {
        self.additions = additions
        self.deletions = deletions
        if let oldPath {
            self.oldPath = oldPath
        }
    }

    mutating func apply(status: GitDiffStatus, oldPath: String?) {
        self.status = status
        if let oldPath {
            self.oldPath = oldPath
        }
    }
}

private struct GitDiffNumstatToken {
    let path: String
    let oldPath: String?
    let additions: Int?
    let deletions: Int?

    init?(token: String, tokens: [String], index: inout Int) {
        let pieces = token.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3 else { return nil }
        additions = Int(pieces[0])
        deletions = Int(pieces[1])
        if pieces[2].isEmpty {
            guard index + 2 < tokens.count else { return nil }
            oldPath = tokens[index + 1]
            path = tokens[index + 2]
            index += 3
        } else {
            oldPath = nil
            path = pieces[2]
            index += 1
        }
    }
}

private struct GitDiffNameStatusToken {
    let path: String
    let oldPath: String?
    let status: GitDiffStatus

    init?(token: String, tokens: [String], index: inout Int) {
        let pieces = token.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let statusRaw = pieces[0]
        guard let first = statusRaw.first else { return nil }
        switch first {
        case "A":
            status = .added
        case "M", "T":
            status = .modified
        case "D":
            status = .deleted
        case "R":
            status = .renamed
        default:
            return nil
        }
        if status == .renamed {
            if pieces.count >= 3 {
                oldPath = pieces[1]
                path = pieces[2]
                index += 1
            } else {
                guard index + 2 < tokens.count else { return nil }
                oldPath = tokens[index + 1]
                path = tokens[index + 2]
                index += 3
            }
        } else if pieces.count >= 2 {
            oldPath = nil
            path = pieces[1]
            index += 1
        } else {
            guard index + 1 < tokens.count else { return nil }
            oldPath = nil
            path = tokens[index + 1]
            index += 2
        }
    }
}
