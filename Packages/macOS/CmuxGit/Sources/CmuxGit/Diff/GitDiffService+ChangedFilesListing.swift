internal import Foundation

struct GitChangedFilesListing: Sendable {
    let numstat: GitProcessResult
    let nameStatus: GitProcessResult
    let untracked: GitProcessResult
    let raw: GitProcessResult

    func hasSameOutput(as other: Self) -> Bool {
        numstat.rawOutput == other.numstat.rawOutput
            && numstat.capped == other.numstat.capped
            && nameStatus.rawOutput == other.nameStatus.rawOutput
            && nameStatus.capped == other.nameStatus.capped
            && untracked.rawOutput == other.untracked.rawOutput
            && untracked.capped == other.untracked.capped
            && raw.rawOutput == other.raw.rawOutput
            && raw.capped == other.raw.capped
    }
}

extension GitDiffService {
    func changedFilesListingResult(
        repoRoot: String,
        baseline: String,
        maxOutputBytes: Int
    ) -> GitDiffQueryResult<GitChangedFilesListing> {
        let numstat = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--ignore-submodules=none", "-O/dev/null", "--numstat", "-z",
                "--no-color", "--find-renames", "--no-ext-diff", "--no-textconv",
            ],
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitChangedFilesListing> = queryFailure(from: numstat) {
            return failure
        }
        let nameStatus = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--ignore-submodules=none", "-O/dev/null", "--name-status", "-z",
                "--no-color", "--find-renames", "--no-ext-diff", "--no-textconv",
            ],
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitChangedFilesListing> = queryFailure(from: nameStatus) {
            return failure
        }
        let untracked = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            maxOutputBytes: maxOutputBytes
        )
        if let failure: GitDiffQueryResult<GitChangedFilesListing> = queryFailure(from: untracked) {
            return failure
        }
        let scaledRawOutputBytes = maxOutputBytes.multipliedReportingOverflow(by: 4)
        let rawOutputBytes = scaledRawOutputBytes.overflow
            ? Int.max
            : max(64 * 1024, scaledRawOutputBytes.partialValue)
        let raw = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--ignore-submodules=none", "-O/dev/null", "--raw", "--full-index",
                "-z", "--no-color", "--find-renames", "--no-ext-diff", "--no-textconv",
            ],
            maxOutputBytes: rawOutputBytes
        )
        if let failure: GitDiffQueryResult<GitChangedFilesListing> = queryFailure(from: raw) {
            return failure
        }
        return .success(
            GitChangedFilesListing(
                numstat: numstat,
                nameStatus: nameStatus,
                untracked: untracked,
                raw: raw
            )
        )
    }
}
