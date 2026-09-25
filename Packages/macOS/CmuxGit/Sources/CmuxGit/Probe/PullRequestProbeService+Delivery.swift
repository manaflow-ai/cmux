import Foundation

private struct PullRequestHeadPayload: Decodable {
    struct Head: Decodable {
        let sha: String
    }

    let head: Head
}

/// GitHub check and deployment status reads for a resolved pull request.
extension PullRequestProbeService {
    /// Fetches the current check-run and deployment-like commit statuses for a PR.
    ///
    /// GitHub exposes the head SHA on the pull-request resource, while checks
    /// and commit statuses are keyed by that SHA. Missing credentials,
    /// unsupported repositories, and provider errors return `nil`, allowing the
    /// caller to retain the last known status without presenting a false error.
    public nonisolated func fetchDeliveryStatus(
        repositorySlug: String,
        pullRequestNumber: Int
    ) async -> PullRequestDeliveryStatus? {
        guard Self.isValidRepositorySlug(repositorySlug), pullRequestNumber > 0,
              let authHeader = await authHeaderValue() else {
            return nil
        }

        let pullRequestEndpoint = "repos/\(repositorySlug)/pulls/\(pullRequestNumber)"
        guard let pullRequestResponse = await performRequest(
            endpoint: pullRequestEndpoint,
            authHeader: authHeader
        ), pullRequestResponse.statusCode == 200,
              let head = try? JSONDecoder().decode(
                  PullRequestHeadPayload.self,
                  from: pullRequestResponse.data
              ) else {
            return nil
        }

        let sha = head.head.sha
        guard !sha.isEmpty else { return nil }
        let endpoints = [
            "repos/\(repositorySlug)/commits/\(sha)/check-runs?per_page=100",
            "repos/\(repositorySlug)/commits/\(sha)/status",
        ]
        let responses = await withTaskGroup(
            of: (Int, WorkspacePullRequestHTTPResponse?).self,
            returning: [WorkspacePullRequestHTTPResponse?].self
        ) { group in
            for (index, endpoint) in endpoints.enumerated() {
                group.addTask {
                    (index, await self.performRequest(endpoint: endpoint, authHeader: authHeader))
                }
            }
            var values = Array<WorkspacePullRequestHTTPResponse?>(repeating: nil, count: endpoints.count)
            for await (index, response) in group {
                values[index] = response
            }
            return values
        }

        let checkResponse = responses[0]
        let statusResponse = responses[1]
        guard checkResponse?.statusCode == 200 || statusResponse?.statusCode == 200 else {
            return nil
        }
        let parsed = PullRequestDeliveryStatusParser().parse(
            checkRunsData: checkResponse?.statusCode == 200 ? checkResponse?.data ?? Data() : Data(),
            commitStatusData: statusResponse?.statusCode == 200 ? statusResponse?.data ?? Data() : Data()
        )
        guard parsed.checks != nil || parsed.deployment != nil else { return nil }
        return parsed
    }

    private static func isValidRepositorySlug(_ slug: String) -> Bool {
        let pieces = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        return pieces.allSatisfy { !$0.isEmpty && !$0.contains(where: { $0 == "?" || $0 == "#" }) }
    }
}
