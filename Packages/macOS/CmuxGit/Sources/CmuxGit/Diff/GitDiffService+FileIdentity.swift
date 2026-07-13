import Foundation

extension GitDiffService {
    /// Distinguishes a deleted file plus untracked replacement (`M`) from an
    /// untracked file at a rename source (`U`). Ordinary rows are validated by
    /// their bounded one-file diff metadata; only this ambiguous shape needs
    /// rename detection outside the requested pathspec. `--find-object` keeps
    /// output scoped to the baseline object instead of scanning every changed
    /// path into memory.
    func statusForUntrackedBaselineReplacement(
        repoRoot: String,
        baseline: String,
        path: String,
        maxOutputBytes: Int
    ) -> GitDiffQueryResult<GitDiffStatus> {
        let objectIDResult = runGit(
            in: repoRoot,
            arguments: ["ls-tree", "--full-tree", "-z", baseline, "--", literalPathspec(path)],
            maxOutputBytes: 64 * 1024
        )
        if let failure: GitDiffQueryResult<GitDiffStatus> = queryFailure(from: objectIDResult) {
            return failure
        }
        guard let objectOutput = objectIDResult.successOutput, !objectIDResult.capped else {
            return .failed
        }
        let objectID = objectOutput.split(separator: "\0", omittingEmptySubsequences: true).lazy
            .compactMap { record -> String? in
                guard let tab = record.firstIndex(of: "\t") else { return nil }
                let metadata = record[..<tab].split(separator: " ", omittingEmptySubsequences: true)
                let recordedPath = record[record.index(after: tab)...]
                guard metadata.count >= 3, recordedPath == path else { return nil }
                return String(metadata[2])
            }
            .first
        guard let objectID else { return .notFound }
        let result = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--name-status", "-z", "--no-color", "--find-renames",
                "--find-object=\(objectID)", "--diff-filter=DR", "--no-ext-diff", "--no-textconv",
            ],
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitDiffStatus> = queryFailure(from: result) {
            return failure
        }
        guard let rawOutput = result.rawOutput else { return .failed }
        let completeOutput: Data
        if result.capped {
            guard let lastNul = rawOutput.lastIndex(of: 0) else { return .failed }
            completeOutput = Data(rawOutput[...lastNul])
        } else {
            completeOutput = rawOutput
        }
        let parsed = parseChangedFiles(
            numstatData: nil,
            nameStatusData: completeOutput,
            untrackedData: nil
        )
        guard !parsed.hasUndecodablePath else { return .failed }
        if parsed.files.contains(where: { $0.status == .renamed && $0.oldPath == path }) {
            return .success(.untracked)
        }
        if parsed.files.contains(where: { $0.status == .deleted && $0.path == path }) {
            return .success(.modified)
        }
        return result.capped ? .failed : .notFound
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
                "diff", baseline, "--no-ext-diff", "--no-textconv", "--no-color",
                "--submodule=short", "--find-renames", "--", literalPathspec(path),
                descendantExclusionPathspec(path),
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
        guard fileSectionStatus(trackedOutput) == .deleted,
              fileSectionStatus(replacementOutput) == .added else { return .notFound }
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
