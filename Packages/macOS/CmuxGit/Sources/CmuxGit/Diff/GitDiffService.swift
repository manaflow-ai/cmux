internal import Darwin
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
        guard case .success(let root) = repositoryRootResult(for: directory) else { return nil }
        return root
    }

    /// Resolves an enclosing repository root without flattening Git failures
    /// into the same result as a directory outside a repository.
    public func repositoryRootResult(for directory: String) -> GitDiffQueryResult<String> {
        let result = runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])
        switch result.failure {
        case .timedOut:
            return .timedOut
        case .unsuccessfulExit:
            return .notFound
        case .cancelled, .launchFailed:
            return .failed
        case nil:
            guard let root = result.successOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !root.isEmpty else { return .notFound }
            return .success(root)
        }
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
    public func changedFiles(repoRoot: String, maxOutputBytes: Int = 4 * 1024 * 1024) -> GitChangedFiles? {
        guard maxOutputBytes > 0 else { return nil }
        guard let baseline = diffBaseline(in: repoRoot) else {
            return nil
        }
        let numstat = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--numstat", "-z", "--no-color", "--find-renames",
                "--no-ext-diff", "--no-textconv",
            ],
            maxOutputBytes: maxOutputBytes
        )
        let nameStatus = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--name-status", "-z", "--no-color", "--find-renames",
                "--no-ext-diff", "--no-textconv",
            ],
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
    ///   - oldPath: Previous repository-relative path for a rename.
    ///   - maxOutputBytes: Upper bound on diff bytes read from git. When the
    ///     output reaches this bound the git process is terminated and the
    ///     bounded prefix (trimmed to a UTF-8 boundary) is returned, so a huge
    ///     diff never accumulates unbounded memory. Callers that cap responses
    ///     should pass their cap plus a small margin so the returned text still
    ///     exceeds the cap and their truncation detection fires.
    /// - Returns: Raw one-file unified diff, or `nil` when git fails.
    public func fileDiff(
        repoRoot: String,
        path: String,
        oldPath: String? = nil,
        maxOutputBytes: Int = 4 * 1024 * 1024
    ) -> GitFileDiff? {
        guard case .success(let diff) = fileDiffResult(
            repoRoot: repoRoot,
            path: path,
            oldPath: oldPath,
            maxOutputBytes: maxOutputBytes
        ) else { return nil }
        return diff
    }

    /// Reads one file diff while distinguishing absence, command failure, and
    /// watchdog timeout for callers that present actionable errors.
    public func fileDiffResult(
        repoRoot: String,
        path: String,
        oldPath: String? = nil,
        maxOutputBytes: Int = 4 * 1024 * 1024
    ) -> GitDiffQueryResult<GitFileDiff> {
        guard maxOutputBytes > 0 else { return .notFound }
        // Validate on a trimmed copy only; the pathspec passed to git must stay
        // byte-exact because repository paths may legitimately start or end
        // with whitespace (`changedFiles` reports them verbatim).
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notFound }
        // Single-file API: a directory-shaped request ("." or a subdirectory)
        // would expand as a leading-directory pathspec into a combined
        // multi-file diff, bypassing the changed-file selection the response
        // is modeled around. Deleted files no longer exist on disk, so this
        // only rejects paths that currently resolve to a directory.
        var isDirectory: ObjCBool = false
        let absolutePath = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(path).path
        let pathExists = FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory)
        let isSymbolicLink = Self.isSymbolicLink(atPath: absolutePath)
        let isActualDirectory = isDirectory.boolValue && !isSymbolicLink
        if pathExists, isActualDirectory {
            switch isExactTrackedGitlink(repoRoot: repoRoot, path: path, maxOutputBytes: maxOutputBytes) {
            case .success(true):
                break
            case .success(false), .notFound:
                return .notFound
            case .failed:
                return .failed
            case .timedOut:
                return .timedOut
            }
        }
        let untracked: Bool
        switch isUntracked(repoRoot: repoRoot, path: path, maxOutputBytes: maxOutputBytes) {
        case .success(let value):
            untracked = value
        case .notFound:
            return .notFound
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        if untracked {
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
            if let failure: GitDiffQueryResult<GitFileDiff> = queryFailure(from: result) {
                return failure
            }
            guard let output = result.successOutput else { return .failed }
            return .success(GitFileDiff(path: path, unifiedDiff: output, truncated: result.capped))
        }
        let baseline: String
        switch diffBaselineResult(in: repoRoot) {
        case .success(let value):
            baseline = value
        case .notFound:
            return .notFound
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        let requestedBaselineEntry: BaselineEntryKind
        switch baselineEntryKind(repoRoot: repoRoot, baseline: baseline, path: path) {
        case .success(let value):
            requestedBaselineEntry = value
        case .notFound:
            return .notFound
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        if pathExists, !isActualDirectory {
            // A baseline tree and a current file can share the same spelling;
            // Git would expand the pathspec to both the file and every deleted
            // descendant instead of returning one file diff.
            guard requestedBaselineEntry != .directory else { return .notFound }
        } else if !pathExists {
            // Deleted paths are valid only when the baseline contains one
            // exact file or gitlink. A missing baseline tree is a directory-
            // shaped request and must not widen to all of its descendants.
            guard requestedBaselineEntry == .file else { return .notFound }
        }
        if let oldPath {
            guard !oldPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .notFound
            }
            switch baselineEntryKind(repoRoot: repoRoot, baseline: baseline, path: oldPath) {
            case .success(.file):
                break
            case .success, .notFound:
                return .notFound
            case .failed:
                return .failed
            case .timedOut:
                return .timedOut
            }
        }
        let diffPaths = [oldPath, path]
            .compactMap { $0 }
            .reduce(into: [String]()) { paths, candidate in
                if !paths.contains(candidate) {
                    paths.append(candidate)
                }
            }
        let result = runGit(
            in: repoRoot,
            arguments: ["diff", baseline, "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--"]
                + diffPaths.map(Self.literalPathspec),
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitFileDiff> = queryFailure(from: result) {
            return failure
        }
        guard let output = result.successOutput else { return .failed }
        return .success(GitFileDiff(path: path, unifiedDiff: output, truncated: result.capped))
    }

    /// Wraps a repository path in `:(literal)` pathspec magic so glob
    /// characters in real filenames (`*`, `?`, `[`) match the file byte-exact
    /// instead of expanding as a wildcard pattern over the whole tree.
    private static func literalPathspec(_ path: String) -> String {
        ":(literal)\(path)"
    }

    /// Whether `path` is an untracked file. The `:(literal)` pathspec keeps a
    /// glob-looking request (`*`, `?`, `[`) from expanding over the whole
    /// untracked tree, and the byte bound caps the listing a directory-shaped
    /// request can still emit (a directory can never equal itself in the
    /// output, so a capped listing only ever fails closed to "tracked").
    private func isUntracked(
        repoRoot: String,
        path: String,
        maxOutputBytes: Int
    ) -> GitDiffQueryResult<Bool> {
        let result = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z", "--", Self.literalPathspec(path)],
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<Bool> = queryFailure(from: result) {
            return failure
        }
        guard let output = result.successOutput else { return .failed }
        return .success(
            output.split(separator: "\0", omittingEmptySubsequences: true).contains(Substring(path))
        )
    }

    private static func isSymbolicLink(atPath path: String) -> Bool {
        var fileStatus = stat()
        guard lstat(path, &fileStatus) == 0 else { return false }
        return fileStatus.st_mode & S_IFMT == S_IFLNK
    }

    /// A gitlink is the only index entry whose working-tree representation is
    /// a directory but whose path is still one exact diffable file. Ordinary
    /// directories must fail closed because `ls-files` pathspecs recursively
    /// match their descendants even with `--error-unmatch`.
    private func isExactTrackedGitlink(
        repoRoot: String,
        path: String,
        maxOutputBytes: Int
    ) -> GitDiffQueryResult<Bool> {
        let validationOutputLimit = min(maxOutputBytes, 64 * 1024)
        let result = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--stage", "-z", "--", Self.literalPathspec(path)],
            maxOutputBytes: validationOutputLimit
        )
        if let failure: GitDiffQueryResult<Bool> = queryFailure(from: result) {
            return failure
        }
        guard let output = result.successOutput, !result.capped else { return .failed }
        let isGitlink = output.split(separator: "\0", omittingEmptySubsequences: true).contains { record in
            guard let tab = record.firstIndex(of: "\t") else { return false }
            let metadata = record[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            let recordedPath = record[record.index(after: tab)...]
            return metadata.first == "160000" && recordedPath == path
        }
        return .success(isGitlink)
    }

    /// Verifies a rename source is one exact file in the selected baseline.
    /// This prevents an untrusted old path such as `.` from widening the
    /// single-file request into a repository-wide diff.
    private func baselineEntryKind(
        repoRoot: String,
        baseline: String,
        path: String
    ) -> GitDiffQueryResult<BaselineEntryKind> {
        let result = runGit(
            in: repoRoot,
            arguments: ["ls-tree", "--full-tree", "-z", baseline, "--", Self.literalPathspec(path)],
            maxOutputBytes: 64 * 1024
        )
        if let failure: GitDiffQueryResult<BaselineEntryKind> = queryFailure(from: result) {
            return failure
        }
        guard let output = result.successOutput, !result.capped else { return .failed }
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let metadata = record[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            let recordedPath = record[record.index(after: tab)...]
            guard metadata.count >= 2, recordedPath == path else { continue }
            if metadata[1] == "blob" || metadata[1] == "commit" {
                return .success(.file)
            }
            if metadata[1] == "tree" {
                return .success(.directory)
            }
        }
        return .success(.missing)
    }

    /// `git diff HEAD` fails before the first commit. In that state Git's
    /// hash-format-aware empty tree is the correct baseline for index and
    /// working-tree changes, including files already staged in the index.
    private func diffBaseline(in repoRoot: String) -> String? {
        guard case .success(let baseline) = diffBaselineResult(in: repoRoot) else { return nil }
        return baseline
    }

    private func diffBaselineResult(in repoRoot: String) -> GitDiffQueryResult<String> {
        let head = runGit(in: repoRoot, arguments: ["rev-parse", "--verify", "--quiet", "HEAD"])
        switch head.failure {
        case nil:
            guard head.successOutput != nil else { return .failed }
            return .success("HEAD")
        case .unsuccessfulExit:
            break
        case .timedOut:
            return .timedOut
        case .cancelled, .launchFailed:
            return .failed
        }
        let emptyTree = runGit(in: repoRoot, arguments: ["hash-object", "-t", "tree", "/dev/null"])
        if let failure: GitDiffQueryResult<String> = queryFailure(from: emptyTree) {
            return failure
        }
        guard let baseline = emptyTree.successOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseline.isEmpty else { return .failed }
        return .success(baseline)
    }

    private func queryFailure<Value: Sendable>(
        from result: GitProcessResult
    ) -> GitDiffQueryResult<Value>? {
        switch result.failure {
        case .timedOut:
            return .timedOut
        case .cancelled, .launchFailed, .unsuccessfulExit:
            return .failed
        case nil:
            return nil
        }
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

private enum BaselineEntryKind: Equatable {
    case missing
    case file
    case directory
}
