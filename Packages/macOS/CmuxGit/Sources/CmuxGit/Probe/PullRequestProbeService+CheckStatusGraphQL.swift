import Foundation

extension PullRequestProbeService {
    /// Fetches CI rollup states for the REST-fetched open PRs in one GraphQL call.
    nonisolated func pullRequestCheckStatuses(
        repoSlug: String,
        pullRequests: [GitHubPullRequestProbeItem],
        session: URLSession,
        authHeader: String?
    ) async -> [Int: PullRequestCheckStatus] {
        guard let authHeader, !authHeader.isEmpty else {
            return [:]
        }
        guard let ownerAndName = Self.ownerAndName(fromRepoSlug: repoSlug) else {
            return [:]
        }
        let pullRequestNumbers = Self.checkStatusPullRequestNumbers(from: pullRequests)
        guard !pullRequestNumbers.isEmpty else {
            return [:]
        }
        let requestBody = WorkspacePullRequestGraphQLRequestBody(
            query: Self.checkStatusGraphQLQuery(pullRequestNumbers: pullRequestNumbers),
            variables: WorkspacePullRequestGraphQLVariables(
                owner: ownerAndName.owner,
                name: ownerAndName.name
            )
        )

        guard let response = await performGraphQLRequest(
            session: session,
            body: requestBody,
            authHeader: authHeader
        ) else {
            debugLog("workspace.prRefresh.checks.fail repo=\(repoSlug) status=nil")
            return [:]
        }
        guard response.statusCode == 200,
              let graphQLResponse = Self.decodeJSON(WorkspacePullRequestGraphQLResponse.self, from: response.data) else {
            debugLog("workspace.prRefresh.checks.fail repo=\(repoSlug) status=\(response.statusCode)")
            return [:]
        }

        let statusesByNumber = Self.checkStatusesByPullRequestNumber(from: graphQLResponse)
        debugLog("workspace.prRefresh.checks.success repo=\(repoSlug) prs=\(statusesByNumber.count)")
        return statusesByNumber
    }

    /// Pull-request numbers whose rollups should be fetched, preserving REST order.
    nonisolated static func checkStatusPullRequestNumbers(
        from pullRequests: [GitHubPullRequestProbeItem]
    ) -> [Int] {
        var seenNumbers: Set<Int> = []
        var numbers: [Int] = []
        for pullRequest in pullRequests where PullRequestStatus(githubState: pullRequest.state) == .open {
            guard seenNumbers.insert(pullRequest.number).inserted else { continue }
            numbers.append(pullRequest.number)
        }
        return numbers
    }

    /// Builds one GraphQL query with aliases for each REST-fetched PR number.
    nonisolated static func checkStatusGraphQLQuery(pullRequestNumbers: [Int]) -> String {
        let fields = pullRequestNumbers.enumerated().map { index, number in
            """
                pr\(index): pullRequest(number: \(number)) {
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
            """
        }.joined(separator: "\n")
        return """
        query PullRequestCheckRollup($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
        \(fields)
          }
        }
        """
    }

    /// Applies fetched CI rollups to probe items without changing PR selection fields.
    nonisolated static func applyingCheckStatuses(
        _ statusesByNumber: [Int: PullRequestCheckStatus],
        to pullRequests: [GitHubPullRequestProbeItem]
    ) -> [GitHubPullRequestProbeItem] {
        guard !statusesByNumber.isEmpty else { return pullRequests }
        return pullRequests.map { pullRequest in
            guard let ciStatus = statusesByNumber[pullRequest.number] else {
                return pullRequest
            }
            return applyingCheckStatus(ciStatus, to: pullRequest)
        }
    }

    /// Looks up an already-cached rollup for a targeted branch lookup.
    nonisolated static func cachedCheckStatus(
        for pullRequest: GitHubPullRequestProbeItem,
        normalizedBranch: String,
        in cacheEntry: WorkspacePullRequestRepoCacheEntry
    ) -> PullRequestCheckStatus? {
        if let status = cacheEntry.pullRequestsByBranch[normalizedBranch]?.ciStatus {
            return status
        }
        return cacheEntry.pullRequestsByBranch.values.first {
            $0.number == pullRequest.number
        }?.ciStatus
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
        let nodes = response.data?.repository?.nodes ?? []
        var statusesByNumber: [Int: PullRequestCheckStatus] = [:]
        for node in nodes {
            guard let node else { continue }
            statusesByNumber[node.number] = node.ciStatus
        }
        return statusesByNumber
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
