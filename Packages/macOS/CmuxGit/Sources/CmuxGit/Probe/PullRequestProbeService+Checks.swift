import CryptoKit
import Foundation

extension PullRequestProbeService {
    /// Fetches current GitHub checks and mergeability using the shared authenticated
    /// transport. Partial or failed check data can never produce a passing badge.
    public nonisolated func fetchPullRequestChecks(
        repoSlug: String,
        pullRequestNumber: Int,
        headSHA: String?
    ) async -> PullRequestChecksSummary? {
        guard !Task.isCancelled, pullRequestNumber > 0,
              GitMetadataService.normalizedGitHubRepositorySlug(repoSlug) == repoSlug,
              let authHeader = await authHeaderValue() else { return nil }
        let identity = Data(SHA256.hash(data: Data(authHeader.utf8))).base64EncodedString()
        let key = "\(identity)|\(repoSlug)#\(pullRequestNumber)|\(headSHA ?? "")"
        if let cached = await checksCache.value(for: key, now: Date()) { return cached }
        guard !Task.isCancelled else { return nil }
        let response = await performRequest(endpoint: "repos/\(repoSlug)/pulls/\(pullRequestNumber)", authHeader: authHeader)
        let detail = response?.decode(WorkspacePullRequestDetailItem.self)
        // The PR detail is newer than the branch lookup when a push races this pass.
        guard let sha = detail?.head?.sha ?? headSHA,
              !sha.isEmpty, sha.allSatisfy({ $0.isHexDigit }), !Task.isCancelled else { return nil }
        async let runs = fetchCheckRuns(repoSlug: repoSlug, sha: sha, authHeader: authHeader)
        async let statuses = fetchCommitStatuses(repoSlug: repoSlug, sha: sha, authHeader: authHeader)
        let (runResult, statusResult) = await (runs, statuses)
        guard !Task.isCancelled else { return nil }
        let checks = (runResult.checks + statusResult.checks).sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
        let summary = PullRequestChecksSummary(
            checks: checks,
            mergeStatus: PullRequestMergeStatus(mergeable: detail?.mergeable, mergeableState: detail?.mergeableState),
            complete: runResult.complete && statusResult.complete
        )
        // Never cache a result under an older commit's identity.
        if summary.status != .unavailable, sha == headSHA {
            await checksCache.insert(summary, for: key, now: Date())
        }
        return summary
    }

}
