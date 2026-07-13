public import Foundation

/// Runs git commands needed by the mobile diff-review flow.
public struct GitDiffService: Sendable {
    let processRunner: GitProcessRunner

    /// Creates a git diff service.
    ///
    /// - Parameters:
    ///   - gitExecutableURL: Git executable URL.
    ///   - fileSystemStatExecutableURL: Filesystem metadata executable URL.
    ///   - environment: Base process environment.
    ///   - processDeadlineSeconds: Wall-clock bound on each git subprocess.
    ///     The mobile RPC timeout cancels only the awaiting task, never the
    ///     spawned process, so a stalled git (fsmonitor hang, dead network
    ///     filesystem) is terminated here instead of accumulating across
    ///     phone retries.
    public init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        fileSystemStatExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/stat"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processDeadlineSeconds: Double = 20
    ) {
        self.processRunner = GitProcessRunner(
            gitExecutableURL: gitExecutableURL,
            fileSystemStatExecutableURL: fileSystemStatExecutableURL,
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
                  let root = removingGitLineTerminator(output),
                  !root.isEmpty else { return .notFound }
            return .success(root)
        }
    }

    /// Reads a unified diff for one repository-relative file path.
    ///
    /// - Parameters:
    ///   - repoRoot: Repository root.
    ///   - path: Repository-relative path.
    ///   - oldPath: Previous repository-relative path for a rename.
    ///   - status: Status from the selected changed-file row. This disambiguates
    ///     a deletion from an untracked replacement at the same path.
    ///   - additions: Added-line count from the selected changed-file row.
    ///   - deletions: Deleted-line count from the selected changed-file row.
    ///   - snapshotToken: Opaque repository-state identity from that row. When
    ///     supplied, the request fails if the baseline, index, or file identity
    ///     changes before the diff finishes loading.
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
        additions: Int? = nil,
        deletions: Int? = nil,
        snapshotToken: String? = nil,
        maxOutputBytes: Int = 4 * 1024 * 1024
    ) -> GitFileDiff? {
        guard case .success(let diff) = fileDiffResult(
            repoRoot: repoRoot,
            path: path,
            oldPath: oldPath,
            status: status,
            additions: additions,
            deletions: deletions,
            snapshotToken: snapshotToken,
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
        additions: Int? = nil,
        deletions: Int? = nil,
        snapshotToken: String? = nil,
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
        let expectedSummary: GitDiffSummary?
        if let snapshotToken {
            guard let status, !snapshotToken.isEmpty else { return .notFound }
            let summary = GitDiffSummary(
                path: path,
                oldPath: oldPath,
                status: status,
                additions: additions,
                deletions: deletions
            )
            guard snapshotMatches(
                snapshotToken,
                repoRoot: repoRoot,
                baseline: baseline,
                summary: summary
            ) else { return .notFound }
            expectedSummary = summary
        } else {
            expectedSummary = nil
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
        let hasUntrackedReplacementShape = requestedBaselineEntry.isFile
            && !indexed
            && untracked
            && oldPath == nil
        if let status, hasUntrackedReplacementShape {
            switch statusForUntrackedBaselineReplacement(
                repoRoot: repoRoot,
                baseline: baseline,
                path: path,
                maxOutputBytes: maxOutputBytes
            ) {
            case .success(let current) where current == status:
                break
            case .success, .notFound:
                return .notFound
            case .failed:
                return .failed
            case .timedOut:
                return .timedOut
            }
        }
        let isUntrackedReplacement = status == .modified && hasUntrackedReplacementShape
        if isUntrackedReplacement {
            let result = untrackedReplacementDiffResult(
                repoRoot: repoRoot,
                baseline: baseline,
                path: path,
                maxOutputBytes: maxOutputBytes
            )
            guard case .success(let diff) = result else { return result }
            return validatedSnapshotResult(
                diff,
                expectedToken: snapshotToken,
                expectedSummary: expectedSummary,
                repoRoot: repoRoot
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
            guard hasExactlyOneFileSection(output) else { return .notFound }
            let diff = GitFileDiff(path: path, unifiedDiff: output, truncated: result.capped)
            return validatedSnapshotResult(
                diff,
                expectedToken: snapshotToken,
                expectedSummary: expectedSummary,
                repoRoot: repoRoot
            )
        }
        let diffPaths = [oldPath, path]
            .compactMap { $0 }
            .reduce(into: [String]()) { paths, candidate in
                if !paths.contains(candidate) {
                    paths.append(candidate)
                }
            }
        var pathspecs = diffPaths.map(literalPathspec)
        if requestedBaselineEntry.excludesDescendants {
            pathspecs.append(descendantExclusionPathspec(path))
        }
        if let oldPath, oldBaselineEntry?.excludesDescendants == true {
            pathspecs.append(descendantExclusionPathspec(oldPath))
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
        guard hasExactlyOneFileSection(output) else { return .notFound }
        if let status, fileSectionStatus(output) != status {
            return .notFound
        }
        if oldPath != nil, !hasRenameHeaders(output) {
            return .notFound
        }
        let diff = GitFileDiff(path: path, unifiedDiff: output, truncated: result.capped)
        return validatedSnapshotResult(
            diff,
            expectedToken: snapshotToken,
            expectedSummary: expectedSummary,
            repoRoot: repoRoot
        )
    }

    private func snapshotMatches(
        _ expectedToken: String,
        repoRoot: String,
        baseline: String,
        summary: GitDiffSummary
    ) -> Bool {
        guard case .success(let context) = snapshotContextResult(
            repoRoot: repoRoot,
            baselineObjectID: baseline
        ), case .success(let currentTokens) = snapshotTokensResult(
            repoRoot: repoRoot,
            context: context,
            summaries: [summary]
        ), currentTokens.count == 1,
        let currentToken = currentTokens.first else { return false }
        return currentToken == expectedToken
    }

    private func validatedSnapshotResult(
        _ diff: GitFileDiff,
        expectedToken: String?,
        expectedSummary: GitDiffSummary?,
        repoRoot: String
    ) -> GitDiffQueryResult<GitFileDiff> {
        guard let expectedToken, let expectedSummary else { return .success(diff) }
        guard case .success(let currentBaseline) = diffBaselineResult(in: repoRoot),
              snapshotMatches(
                expectedToken,
                repoRoot: repoRoot,
                baseline: currentBaseline,
                summary: expectedSummary
              ) else { return .notFound }
        return .success(diff)
    }

    /// Wraps a repository path in `:(literal)` pathspec magic so glob
    /// characters in real filenames (`*`, `?`, `[`) match the file byte-exact
    /// instead of expanding as a wildcard pattern over the whole tree.
    func literalPathspec(_ path: String) -> String {
        ":(literal)\(path)"
    }

    /// Excludes descendants when Git compares an exact file request. This is
    /// inert for ordinary files, but prevents a baseline directory replaced by
    /// an indexed file from widening the response to deleted children.
    func descendantExclusionPathspec(_ path: String) -> String {
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
            arguments: ["ls-files", "--others", "--exclude-standard", "-z", "--", literalPathspec(path)],
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
            arguments: ["ls-files", "--stage", "-z", "--", literalPathspec(path)],
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
            arguments: ["ls-tree", "--full-tree", "-z", baseline, "--", literalPathspec(path)],
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
