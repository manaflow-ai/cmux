public import Foundation

/// Runs git commands needed by the mobile diff-review flow.
public struct GitDiffService: Sendable {
    private let processRunner: GitProcessRunner

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
        self.processRunner = GitProcessRunner(
            gitExecutableURL: gitExecutableURL,
            environment: environment,
            processDeadlineSeconds: processDeadlineSeconds
        )
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
    /// - Returns: Changed-file summaries in path order with a truncation marker,
    ///   or `nil` when any required git command fails or times out.
    public func changedFiles(repoRoot: String, maxOutputBytes: Int? = nil) -> GitChangedFiles? {
        guard let baseline = diffBaseline(in: repoRoot) else {
            return nil
        }
        let numstat = runGit(
            in: repoRoot,
            arguments: ["diff", baseline, "--numstat", "-z", "--no-color", "--find-renames"],
            maxOutputBytes: maxOutputBytes
        )
        let nameStatus = runGit(
            in: repoRoot,
            arguments: ["diff", baseline, "--name-status", "-z", "--no-color", "--find-renames"],
            maxOutputBytes: maxOutputBytes
        )
        let untracked = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            maxOutputBytes: maxOutputBytes
        )
        guard numstat.successOutput != nil,
              nameStatus.successOutput != nil,
              untracked.successOutput != nil,
              !numstat.timedOut,
              !nameStatus.timedOut,
              !untracked.timedOut else { return nil }
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
           isDirectory.boolValue,
           !isExactTrackedGitlink(repoRoot: repoRoot, path: path, maxOutputBytes: maxOutputBytes) {
            return nil
        }
        if isUntracked(repoRoot: repoRoot, path: path, maxOutputBytes: maxOutputBytes) {
            // In `--no-index` mode a bare `-` names stdin even after `--`.
            // Prefix only the git-side spelling while preserving the API path.
            let gitPath = path == "-" ? "./-" : path
            let result = runGit(
                in: repoRoot,
                // `--no-ext-diff --no-textconv`: this output feeds a
                // machine parser, so repo/user-configured `diff.external`
                // or textconv drivers must neither execute nor replace the
                // unified format.
                arguments: ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", gitPath],
                acceptedTerminationStatuses: [0, 1],
                maxOutputBytes: maxOutputBytes
            )
            guard let output = result.successOutput, !result.timedOut else { return nil }
            return GitFileDiff(path: path, unifiedDiff: output, truncated: result.capped)
        }
        guard let baseline = diffBaseline(in: repoRoot) else { return nil }
        let result = runGit(
            in: repoRoot,
            arguments: ["diff", baseline, "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--", Self.literalPathspec(path)],
            maxOutputBytes: maxOutputBytes
        )
        guard let output = result.successOutput, !result.timedOut else { return nil }
        return GitFileDiff(path: path, unifiedDiff: output, truncated: result.capped)
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

    /// A gitlink is the only index entry whose working-tree representation is
    /// a directory but whose path is still one exact diffable file. Ordinary
    /// directories must fail closed because `ls-files` pathspecs recursively
    /// match their descendants even with `--error-unmatch`.
    private func isExactTrackedGitlink(
        repoRoot: String,
        path: String,
        maxOutputBytes: Int?
    ) -> Bool {
        let validationOutputLimit = min(maxOutputBytes ?? 64 * 1024, 64 * 1024)
        let result = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--stage", "-z", "--", Self.literalPathspec(path)],
            maxOutputBytes: validationOutputLimit
        )
        guard let output = result.successOutput,
              !result.capped,
              !result.timedOut else { return false }
        return output.split(separator: "\0", omittingEmptySubsequences: true).contains { record in
            guard let tab = record.firstIndex(of: "\t") else { return false }
            let metadata = record[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            let recordedPath = record[record.index(after: tab)...]
            return metadata.first == "160000" && recordedPath == path
        }
    }

    /// `git diff HEAD` fails before the first commit. In that state Git's
    /// hash-format-aware empty tree is the correct baseline for index and
    /// working-tree changes, including files already staged in the index.
    private func diffBaseline(in repoRoot: String) -> String? {
        if runGit(in: repoRoot, arguments: ["rev-parse", "--verify", "--quiet", "HEAD"]).successOutput != nil {
            return "HEAD"
        }
        return runGit(in: repoRoot, arguments: ["hash-object", "-t", "tree", "/dev/null"]).successOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(
        in directory: String,
        arguments: [String],
        acceptedTerminationStatuses: Set<Int32> = [0],
        maxOutputBytes: Int? = nil
    ) -> GitProcessResult {
        processRunner.run(
            in: directory,
            arguments: arguments,
            acceptedTerminationStatuses: acceptedTerminationStatuses,
            maxOutputBytes: maxOutputBytes
        )
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
