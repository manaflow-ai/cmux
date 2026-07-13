public import Foundation

/// Runs git commands needed by the mobile diff-review flow.
public struct GitDiffService: Sendable {
    let processRunner: GitProcessRunner

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
            guard let output = result.successOutput,
                  let root = Self.removingGitLineTerminator(output),
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
    ///   or `nil` when any required Git command fails or times out.
    public func changedFiles(repoRoot: String, maxOutputBytes: Int = 4 * 1024 * 1024) -> GitChangedFiles? {
        guard case .success(let changed) = changedFilesResult(
            repoRoot: repoRoot,
            maxOutputBytes: maxOutputBytes
        ) else { return nil }
        return changed
    }

    /// Lists changed files while preserving timeout and execution failures for
    /// callers that present actionable errors.
    public func changedFilesResult(
        repoRoot: String,
        maxOutputBytes: Int = 4 * 1024 * 1024
    ) -> GitDiffQueryResult<GitChangedFiles> {
        guard maxOutputBytes > 0 else { return .notFound }
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
        let numstat = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--numstat", "-z", "--no-color", "--find-renames",
                "--no-ext-diff", "--no-textconv",
            ],
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitChangedFiles> = queryFailure(from: numstat) {
            return failure
        }
        let nameStatus = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--name-status", "-z", "--no-color", "--find-renames",
                "--no-ext-diff", "--no-textconv",
            ],
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitChangedFiles> = queryFailure(from: nameStatus) {
            return failure
        }
        let untracked = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitChangedFiles> = queryFailure(from: untracked) {
            return failure
        }
        guard let numstatData = completeRecordData(numstat),
              let nameStatusData = completeRecordData(nameStatus),
              let untrackedData = completeRecordData(untracked) else { return .failed }
        let parsed = parseChangedFiles(
            numstatData: numstatData,
            nameStatusData: nameStatusData,
            untrackedData: untrackedData
        )
        // Git paths are byte identities, while the mobile protocol uses Swift
        // strings. Failing the snapshot is safer than silently dropping an
        // undecodable entry and claiming the visible list is complete.
        guard !parsed.hasUndecodablePath else { return .failed }
        return .success(
            GitChangedFiles(
                files: parsed.files,
                truncated: numstat.capped || nameStatus.capped || untracked.capped
            )
        )
    }

    /// Drops the trailing partial NUL-separated record a byte cap can leave
    /// behind, so capped listings only contribute complete records.
    private func completeRecordData(_ result: GitProcessResult) -> Data? {
        guard let output = result.rawOutput else { return nil }
        guard result.capped else { return output }
        guard let lastNul = output.lastIndex(of: 0) else { return Data() }
        return Data(output[...lastNul])
    }

    /// Reads a unified diff for one repository-relative file path.
    ///
    /// - Parameters:
    ///   - repoRoot: Repository root.
    ///   - path: Repository-relative path.
    ///   - oldPath: Previous repository-relative path for a rename.
    ///   - status: Status from the selected changed-file row. This disambiguates
    ///     a deletion from an untracked replacement at the same path.
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
        status: GitDiffStatus? = nil,
        maxOutputBytes: Int = 4 * 1024 * 1024
    ) -> GitFileDiff? {
        guard case .success(let diff) = fileDiffResult(
            repoRoot: repoRoot,
            path: path,
            oldPath: oldPath,
            status: status,
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
        status: GitDiffStatus? = nil,
        maxOutputBytes: Int = 4 * 1024 * 1024
    ) -> GitDiffQueryResult<GitFileDiff> {
        guard maxOutputBytes > 0 else { return .notFound }
        // Validate on a trimmed copy only; the pathspec passed to git must stay
        // byte-exact because repository paths may legitimately start or end
        // with whitespace (`changedFiles` reports them verbatim).
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notFound }
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
        let indexed: Bool
        switch isExactIndexedEntry(repoRoot: repoRoot, path: path, maxOutputBytes: maxOutputBytes) {
        case .success(let value):
            indexed = value
        case .notFound:
            return .notFound
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
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
        if let status {
            switch currentFileSummary(
                repoRoot: repoRoot,
                baseline: baseline,
                path: path,
                isUntracked: untracked,
                maxOutputBytes: maxOutputBytes
            ) {
            case .success(let current) where current.status == status && current.oldPath == oldPath:
                break
            case .success, .notFound:
                return .notFound
            case .failed:
                return .failed
            case .timedOut:
                return .timedOut
            }
        }
        // With no exact baseline, index, or untracked entry, this is either a
        // directory-shaped pathspec or a missing path. A baseline directory is
        // accepted only when the current tree has an exact file replacement.
        // Fail closed before a diff command can expand the request to children.
        guard requestedBaselineEntry.isFile || indexed || untracked else {
            return .notFound
        }
        var oldBaselineEntry: BaselineEntryKind?
        if let oldPath {
            guard !oldPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .notFound
            }
            switch baselineEntryKind(repoRoot: repoRoot, baseline: baseline, path: oldPath) {
            case .success(let entry) where entry.isFile:
                oldBaselineEntry = entry
            case .success, .notFound:
                return .notFound
            case .failed:
                return .failed
            case .timedOut:
                return .timedOut
            }
        }
        let isUntrackedReplacement = status == .modified
            && requestedBaselineEntry.isFile
            && !indexed
            && untracked
            && oldPath == nil
        if isUntrackedReplacement {
            return untrackedReplacementDiffResult(
                repoRoot: repoRoot,
                baseline: baseline,
                path: path,
                maxOutputBytes: maxOutputBytes
            )
        }
        let shouldDiffAsUntracked = status == .untracked
            || (status == nil && untracked && !requestedBaselineEntry.isFile)
        if status == .untracked, !untracked {
            return .notFound
        }
        if shouldDiffAsUntracked {
            // An untracked destination cannot be the second half of a tracked
            // rename. Fail closed instead of silently ignoring `oldPath` and
            // returning an unrelated new-file diff.
            guard oldPath == nil else { return .notFound }
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
            guard Self.hasExactlyOneFileSection(output) else { return .notFound }
            return .success(GitFileDiff(path: path, unifiedDiff: output, truncated: result.capped))
        }
        let diffPaths = [oldPath, path]
            .compactMap { $0 }
            .reduce(into: [String]()) { paths, candidate in
                if !paths.contains(candidate) {
                    paths.append(candidate)
                }
            }
        var pathspecs = diffPaths.map(Self.literalPathspec)
        if requestedBaselineEntry.excludesDescendants {
            pathspecs.append(Self.descendantExclusionPathspec(path))
        }
        if let oldPath, oldBaselineEntry?.excludesDescendants == true {
            pathspecs.append(Self.descendantExclusionPathspec(oldPath))
        }
        let result = runGit(
            in: repoRoot,
            arguments: ["diff", baseline, "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--"]
                + pathspecs,
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitFileDiff> = queryFailure(from: result) {
            return failure
        }
        guard let output = result.successOutput else { return .failed }
        guard Self.hasExactlyOneFileSection(output) else { return .notFound }
        if let status, Self.fileSectionStatus(output) != status {
            return .notFound
        }
        if oldPath != nil, !Self.hasRenameHeaders(output) {
            return .notFound
        }
        return .success(GitFileDiff(path: path, unifiedDiff: output, truncated: result.capped))
    }

    /// Wraps a repository path in `:(literal)` pathspec magic so glob
    /// characters in real filenames (`*`, `?`, `[`) match the file byte-exact
    /// instead of expanding as a wildcard pattern over the whole tree.
    static func literalPathspec(_ path: String) -> String {
        ":(literal)\(path)"
    }

    /// Excludes descendants when Git compares an exact file request. This is
    /// inert for ordinary files, but prevents a baseline directory replaced by
    /// an indexed file from widening the response to deleted children.
    static func descendantExclusionPathspec(_ path: String) -> String {
        ":(top,literal,exclude)\(path)/"
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

    /// Whether the index contains one entry at exactly `path`. Files,
    /// symlinks, and gitlinks all have exact records; ordinary directories do
    /// not, so this classification needs no unsupervised filesystem probes.
    private func isExactIndexedEntry(
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
        let isExactEntry = output.split(separator: "\0", omittingEmptySubsequences: true).contains { record in
            guard let tab = record.firstIndex(of: "\t") else { return false }
            let recordedPath = record[record.index(after: tab)...]
            return recordedPath == path
        }
        return .success(isExactEntry)
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
            if metadata[1] == "blob" {
                return .success(.file)
            }
            if metadata[1] == "commit" {
                return .success(.gitlink)
            }
            if metadata[1] == "tree" {
                return .success(.directory)
            }
        }
        return .success(.missing)
    }

}

private enum BaselineEntryKind: Equatable {
    case missing
    case file
    case gitlink
    case directory

    var isFile: Bool {
        self == .file || self == .gitlink
    }

    var excludesDescendants: Bool {
        self == .file || self == .directory
    }
}
