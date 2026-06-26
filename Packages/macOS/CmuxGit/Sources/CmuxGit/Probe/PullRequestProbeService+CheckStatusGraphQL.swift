import Foundation

extension PullRequestProbeService {
    private static let checkStatusGraphQLQuery = """
    query PullRequestCheckRollup($owner: String!, $name: String!, $first: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: $first, orderBy: { field: UPDATED_AT, direction: DESC }) {
          nodes {
            number
            headRefName
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    state
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    /// Fetches CI rollup states for recent open PRs in one GraphQL call.
    nonisolated func pullRequestCheckStatuses(
        repoSlug: String,
        session: URLSession,
        authHeader: String?
    ) async -> (byNumber: [Int: PullRequestCheckStatus], byBranch: [String: PullRequestCheckStatus]) {
        guard let authHeader, !authHeader.isEmpty else {
            return ([:], [:])
        }
        guard let ownerAndName = Self.ownerAndName(fromRepoSlug: repoSlug) else {
            return ([:], [:])
        }
        let requestBody = WorkspacePullRequestGraphQLRequestBody(
            query: Self.checkStatusGraphQLQuery,
            variables: WorkspacePullRequestGraphQLVariables(
                owner: ownerAndName.owner,
                name: ownerAndName.name,
                first: Self.repoPageSize
            )
        )

        guard let response = await performGraphQLRequest(
            session: session,
            body: requestBody,
            authHeader: authHeader
        ) else {
            debugLog("workspace.prRefresh.checks.fail repo=\(repoSlug) status=nil")
            return ([:], [:])
        }
        guard response.statusCode == 200,
              let graphQLResponse = Self.decodeJSON(WorkspacePullRequestGraphQLResponse.self, from: response.data) else {
            debugLog("workspace.prRefresh.checks.fail repo=\(repoSlug) status=\(response.statusCode)")
            return ([:], [:])
        }

        let statusesByNumber = Self.checkStatusesByPullRequestNumber(from: graphQLResponse)
        let statusesByBranch = Self.checkStatusesByNormalizedBranch(from: graphQLResponse)
        debugLog("workspace.prRefresh.checks.success repo=\(repoSlug) prs=\(statusesByNumber.count)")
        return (statusesByNumber, statusesByBranch)
    }

    /// Applies fetched CI rollups to probe items without changing PR selection fields.
    nonisolated static func applyingCheckStatuses(
        _ statusesByNumber: [Int: PullRequestCheckStatus],
        byBranch statusesByBranch: [String: PullRequestCheckStatus] = [:],
        to pullRequests: [GitHubPullRequestProbeItem]
    ) -> [GitHubPullRequestProbeItem] {
        guard !statusesByNumber.isEmpty || !statusesByBranch.isEmpty else { return pullRequests }
        return pullRequests.map { pullRequest in
            let normalizedBranch = GitMetadataService.normalizedBranchName(pullRequest.headRefName)
            guard let ciStatus = statusesByNumber[pullRequest.number]
                ?? normalizedBranch.flatMap({ statusesByBranch[$0] }) else {
                return pullRequest
            }
            return applyingCheckStatus(ciStatus, to: pullRequest)
        }
    }

    /// Applies one CI rollup to one probe item.
    nonisolated static func applyingCheckStatus(
        _ ciStatus: PullRequestCheckStatus,
        to pullRequest: GitHubPullRequestProbeItem
    ) -> GitHubPullRequestProbeItem {
        GitHubPullRequestProbeItem(
            number: pullRequest.number,
            state: pullRequest.state,
            url: pullRequest.url,
            updatedAt: pullRequest.updatedAt,
            mergedAt: pullRequest.mergedAt,
            headRefName: pullRequest.headRefName,
            baseRefName: pullRequest.baseRefName,
            ciStatus: ciStatus
        )
    }

    /// Reduces the GraphQL response to PR-number keyed rollup states.
    nonisolated static func checkStatusesByPullRequestNumber(
        from response: WorkspacePullRequestGraphQLResponse
    ) -> [Int: PullRequestCheckStatus] {
        let nodes = response.data?.repository?.pullRequests.nodes ?? []
        var statusesByNumber: [Int: PullRequestCheckStatus] = [:]
        for node in nodes {
            guard let node else { continue }
            statusesByNumber[node.number] = node.ciStatus
        }
        return statusesByNumber
    }

    /// Reduces the GraphQL response to normalized-branch keyed rollup states.
    nonisolated static func checkStatusesByNormalizedBranch(
        from response: WorkspacePullRequestGraphQLResponse
    ) -> [String: PullRequestCheckStatus] {
        let nodes = response.data?.repository?.pullRequests.nodes ?? []
        var statusesByBranch: [String: PullRequestCheckStatus] = [:]
        for node in nodes {
            guard let node,
                  let normalizedBranch = GitMetadataService.normalizedBranchName(node.headRefName) else {
                continue
            }
            statusesByBranch[normalizedBranch] = node.ciStatus
        }
        return statusesByBranch
    }

    /// One POST against the GitHub GraphQL API; `nil` on transport or encode errors.
    nonisolated func performGraphQLRequest(
        session: URLSession,
        body: WorkspacePullRequestGraphQLRequestBody,
        authHeader: String
    ) async -> WorkspacePullRequestHTTPResponse? {
        guard let url = URL(string: "https://api.github.com/graphql"),
              let encodedBody = try? JSONEncoder().encode(body) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("cmux-workspace-pr-poller", forHTTPHeaderField: "User-Agent")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = encodedBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            return WorkspacePullRequestHTTPResponse(
                statusCode: httpResponse.statusCode,
                data: data
            )
        } catch {
            return nil
        }
    }

    nonisolated static func ownerAndName(fromRepoSlug repoSlug: String) -> (owner: String, name: String)? {
        let components = repoSlug.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty else {
            return nil
        }
        return (components[0], components[1])
    }
}
