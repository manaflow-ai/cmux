internal import Foundation

extension GitDiffService {
    /// Lists changed files relative to `HEAD`, including untracked files.
    ///
    /// - Parameters:
    ///   - repoRoot: Repository root.
    ///   - maxOutputBytes: Per-listing bound on git output. When a listing
    ///     reaches the bound its subprocess is terminated, the trailing
    ///     partial record is dropped, and the result is marked truncated, so
    ///     a workspace with an enormous change set cannot accumulate
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
        let initialContext: SnapshotContext
        switch snapshotContextResult(repoRoot: repoRoot, baselineObjectID: baseline) {
        case .success(let value):
            initialContext = value
        case .notFound, .failed:
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
        let verifiedNameStatusPath = nameStatus.capped
            ? maximumParsedPath(inNameStatusData: nameStatusData)
            : nil
        let verifiedFiles = parsed.files.filter { summary in
            guard summary.status == .untracked, nameStatus.capped else { return true }
            guard let verifiedNameStatusPath else { return false }
            return !Self.gitPathPrecedes(verifiedNameStatusPath, summary.path)
        }
        let finalContext: SnapshotContext
        switch snapshotContextResult(repoRoot: repoRoot, baselineObjectID: baseline) {
        case .success(let value):
            finalContext = value
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        guard finalContext == initialContext else { return .failed }
        var snapshotFiles: [GitDiffSummary] = []
        snapshotFiles.reserveCapacity(verifiedFiles.count)
        for summary in verifiedFiles {
            let token: String
            switch snapshotTokenResult(repoRoot: repoRoot, context: finalContext, summary: summary) {
            case .success(let value):
                token = value
            case .notFound, .failed:
                return .failed
            case .timedOut:
                return .timedOut
            }
            snapshotFiles.append(
                GitDiffSummary(
                    path: summary.path,
                    oldPath: summary.oldPath,
                    status: summary.status,
                    additions: summary.additions,
                    deletions: summary.deletions,
                    snapshotToken: token
                )
            )
        }
        return .success(
            GitChangedFiles(
                files: snapshotFiles,
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
}
