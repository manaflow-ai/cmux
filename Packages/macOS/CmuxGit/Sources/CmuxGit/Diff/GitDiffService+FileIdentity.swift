import Foundation

extension GitDiffService {
    /// Rebuilds the selected row's status identity from one complete tracked
    /// snapshot plus the already-probed exact untracked path. A path-limited
    /// Git diff can misclassify a rename source as a deletion, so freshness
    /// validation must retain global rename detection.
    func currentFileSummary(
        repoRoot: String,
        baseline: String,
        path: String,
        isUntracked: Bool,
        maxOutputBytes: Int
    ) -> GitDiffQueryResult<GitDiffSummary> {
        let result = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--name-status", "-z", "--no-color", "--find-renames",
                "--no-ext-diff", "--no-textconv",
            ],
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitDiffSummary> = queryFailure(from: result) {
            return failure
        }
        guard let nameStatusData = result.rawOutput, !result.capped else { return .failed }
        var untrackedData: Data?
        if isUntracked {
            var exactPath = Data(path.utf8)
            exactPath.append(0)
            untrackedData = exactPath
        }
        let parsed = parseChangedFiles(
            numstatData: nil,
            nameStatusData: nameStatusData,
            untrackedData: untrackedData
        )
        guard !parsed.hasUndecodablePath else { return .failed }
        guard let summary = parsed.files.first(where: { $0.path == path }) else {
            return .notFound
        }
        return .success(summary)
    }

    /// Returns both halves of a staged deletion followed by an untracked file
    /// at the same path. Comparing the old blob directly to the worktree would
    /// hide an identical replacement and would lose gitlink semantics.
    func untrackedReplacementDiffResult(
        repoRoot: String,
        baseline: String,
        path: String,
        maxOutputBytes: Int
    ) -> GitDiffQueryResult<GitFileDiff> {
        guard maxOutputBytes >= 3 else { return .notFound }
        let availableOutputBytes = maxOutputBytes - 1
        let trackedOutputBytes = availableOutputBytes / 2
        let replacementOutputBytes = availableOutputBytes - trackedOutputBytes
        let trackedResult = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--",
                Self.literalPathspec(path), Self.descendantExclusionPathspec(path),
            ],
            maxOutputBytes: trackedOutputBytes
        )
        if let failure: GitDiffQueryResult<GitFileDiff> = queryFailure(from: trackedResult) {
            return failure
        }
        let gitPath = path == "-" ? "./-" : path
        let replacementResult = runGit(
            in: repoRoot,
            arguments: [
                "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--",
                "/dev/null", gitPath,
            ],
            acceptedTerminationStatuses: [0, 1],
            maxOutputBytes: replacementOutputBytes
        )
        if let failure: GitDiffQueryResult<GitFileDiff> = queryFailure(from: replacementResult) {
            return failure
        }
        guard let trackedOutput = trackedResult.successOutput,
              let replacementOutput = replacementResult.successOutput else { return .failed }
        guard Self.fileSectionStatus(trackedOutput) == .deleted,
              Self.fileSectionStatus(replacementOutput) == .added else { return .notFound }
        let separator = trackedOutput.hasSuffix("\n") ? "" : "\n"
        return .success(
            GitFileDiff(
                path: path,
                unifiedDiff: trackedOutput + separator + replacementOutput,
                truncated: trackedResult.capped || replacementResult.capped
            )
        )
    }
}
