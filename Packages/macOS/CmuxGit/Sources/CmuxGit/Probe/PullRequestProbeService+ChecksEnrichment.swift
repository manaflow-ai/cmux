public import Foundation

extension PullRequestProbeService {
    /// Adds optional check details to every resolved PR concurrently. Results
    /// that cannot identify a repository or commit remain unchanged.
#if compiler(>=6.2)
    @concurrent
#endif
    /// Runs optional checks work with caller-controlled cache reuse.
    public nonisolated func enrichPullRequestChecks(
        _ results: [WorkspacePullRequestRefreshResult],
        allowCachedResults: Bool = true
    ) async -> (results: [WorkspacePullRequestRefreshResult], rateLimitRetryDate: Date?) {
        let summaries = await withTaskGroup(
            of: (Int, PullRequestChecksSummary?).self,
            returning: [Int: PullRequestChecksSummary].self
        ) { group in
            for (index, result) in results.enumerated() {
                guard case .resolved(let item) = result.resolution,
                      item.statusRawValue == "open", !item.repoSlug.isEmpty else { continue }
                group.addTask {
                    let checks = await self.fetchPullRequestChecks(
                        repoSlug: item.repoSlug,
                        pullRequestNumber: item.number,
                        headSHA: item.headSHA,
                        allowCachedResults: allowCachedResults
                    )
                    return (index, checks ?? PullRequestChecksSummary(status: .unavailable, checks: [], mergeStatus: .unknown))
                }
            }

            var summaries: [Int: PullRequestChecksSummary] = [:]
            for await (index, summary) in group {
                if let summary { summaries[index] = summary }
            }
            return summaries
        }
        let retryDate: Date?
        if let header = await authHeaderValue() {
            retryDate = await requestCoordinator.retryDate(authHeader: header, resource: .graphql)
        } else {
            retryDate = nil
        }
        return (summaries.mapResults(results), retryDate)
    }
}

private extension Dictionary where Key == Int, Value == PullRequestChecksSummary {
    func mapResults(_ results: [WorkspacePullRequestRefreshResult]) -> [WorkspacePullRequestRefreshResult] {
        results.enumerated().map { index, result in
            guard case .resolved(let item) = result.resolution,
                  let summary = self[index] else {
                return result
            }
            let enriched = WorkspacePullRequestRefreshResult.Resolution.resolved(
                item.withChecks(summary)
            )
            return WorkspacePullRequestRefreshResult(
                workspaceId: result.workspaceId,
                panelId: result.panelId,
                resolution: enriched,
                usedCachedRepoData: result.usedCachedRepoData
            )
        }
    }
}
