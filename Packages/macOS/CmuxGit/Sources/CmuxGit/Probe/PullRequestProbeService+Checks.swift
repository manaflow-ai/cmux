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
        let detail = Self.decodeChecksResponse(WorkspacePullRequestDetailItem.self, response)
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
            status: Self.overallCheckStatus(checks, complete: runResult.complete && statusResult.complete),
            checks: checks,
            mergeStatus: Self.mergeStatus(mergeable: detail?.mergeable, mergeableState: detail?.mergeableState)
        )
        // Never cache a result under an older commit's identity.
        if summary.status != .unavailable, sha == headSHA {
            await checksCache.insert(summary, for: key, now: Date())
        }
        return summary
    }

    nonisolated static func checkStatus(status: String, conclusion: String?) -> PullRequestCheckStatus {
        guard status.lowercased() == "completed" else { return .pending }
        switch conclusion?.lowercased() {
        case "success": return .success
        case "neutral", "skipped": return .neutral
        case "failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale": return .failure
        default: return .unavailable
        }
    }

    nonisolated static func overallCheckStatus(
        _ checks: [PullRequestCheck], complete: Bool = true
    ) -> PullRequestCheckStatus {
        if checks.contains(where: { $0.status == .failure }) { return .failure }
        if checks.contains(where: { $0.status == .pending }) { return .pending }
        guard complete, !checks.contains(where: { $0.status == .unavailable }) else { return .unavailable }
        guard checks.contains(where: { $0.status == .success }) else { return .neutral }
        return .success
    }

    nonisolated static func mergeStatus(
        mergeable: Bool?, mergeableState: String?
    ) -> PullRequestMergeStatus {
        if mergeable == false || mergeableState?.lowercased() == "dirty" { return .conflict }
        switch mergeableState?.lowercased() {
        case "blocked", "unstable", "draft", "behind": return .blocked
        default: return mergeable == true ? .ready : .unknown
        }
    }

    nonisolated static func decodeChecksResponse<T: Decodable>(
        _ type: T.Type, _ response: WorkspacePullRequestHTTPResponse?
    ) -> T? {
        guard let response, response.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: response.data)
    }
}
