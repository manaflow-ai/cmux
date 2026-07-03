import Foundation

extension PullRequestProbeService {
    /// Fetches open-PR CI rollups for one repository with one token-gated GraphQL request.
    nonisolated func pullRequestCIStatusesByNumber(
        repoSlug: String,
        session: URLSession,
        authHeader: String?
    ) async -> [Int: PullRequestCIStatus]? {
        guard let authHeader, !authHeader.isEmpty else {
            return [:]
        }
        guard let repository = Self.repositoryParts(repoSlug: repoSlug) else {
            return nil
        }

        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: OPEN, first: 100) {
              nodes {
                number
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
        let request = GitHubGraphQLRequest(
            query: query,
            variables: [
                "owner": repository.owner,
                "name": repository.name,
            ]
        )
        guard let response = await performGraphQLRequest(
            session: session,
            request: request,
            authHeader: authHeader
        ) else {
            debugLog("workspace.prRefresh.ci.fail repo=\(repoSlug)")
            return nil
        }
        return response.ciStatusesByPullRequestNumber
    }

    /// Marks a repo cache entry as carrying CI rollups and applies those rollups to cached PR items.
    nonisolated static func repoCacheEntry(
        _ entry: WorkspacePullRequestRepoCacheEntry,
        applyingCIStatuses ciStatusesByNumber: [Int: PullRequestCIStatus],
        fetchedAt: Date
    ) -> WorkspacePullRequestRepoCacheEntry {
        WorkspacePullRequestRepoCacheEntry(
            fetchedAt: fetchedAt,
            pullRequestsByBranch: entry.pullRequestsByBranch.mapValues {
                $0.withCIStatus(ciStatusesByNumber[$0.number] ?? .neutral)
            },
            knownAbsentBranches: entry.knownAbsentBranches,
            includesCIStatus: true,
            ciStatusByPullRequestNumber: ciStatusesByNumber
        )
    }

    /// Whether a fresh cache entry can satisfy a request with or without CI data.
    nonisolated static func cachedEntrySatisfiesRequest(
        _ entry: WorkspacePullRequestRepoCacheEntry,
        now: Date,
        includeCIStatus: Bool
    ) -> Bool {
        now.timeIntervalSince(entry.fetchedAt) < Self.repoCacheLifetime
            && (!includeCIStatus || entry.includesCIStatus)
    }

    private nonisolated static func repositoryParts(repoSlug: String) -> (owner: String, name: String)? {
        let parts = repoSlug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        return (parts[0], parts[1])
    }

    private nonisolated func performGraphQLRequest(
        session: URLSession,
        request graphQLRequest: GitHubGraphQLRequest,
        authHeader: String
    ) async -> GitHubPullRequestCIStatusGraphQLResponse? {
        guard let url = URL(string: "https://api.github.com/graphql"),
              let body = try? JSONEncoder().encode(graphQLRequest) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("cmux-workspace-pr-poller", forHTTPHeaderField: "User-Agent")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            return Self.decodeJSON(GitHubPullRequestCIStatusGraphQLResponse.self, from: data)
        } catch {
            return nil
        }
    }
}

private struct GitHubGraphQLRequest: Encodable {
    let query: String
    let variables: [String: String]
}

struct GitHubPullRequestCIStatusGraphQLResponse: Decodable, Sendable {
    struct DataContainer: Decodable, Sendable {
        let repository: Repository?
    }

    struct Repository: Decodable, Sendable {
        let pullRequests: PullRequestConnection
    }

    struct PullRequestConnection: Decodable, Sendable {
        let nodes: [PullRequestNode?]?
    }

    struct PullRequestNode: Decodable, Sendable {
        let number: Int
        let commits: CommitConnection?
    }

    struct CommitConnection: Decodable, Sendable {
        let nodes: [CommitNode?]?
    }

    struct CommitNode: Decodable, Sendable {
        let commit: Commit
    }

    struct Commit: Decodable, Sendable {
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable, Sendable {
        let state: String?
    }

    let data: DataContainer?

    var ciStatusesByPullRequestNumber: [Int: PullRequestCIStatus] {
        var statuses: [Int: PullRequestCIStatus] = [:]
        for pullRequest in data?.repository?.pullRequests.nodes ?? [] {
            guard let pullRequest else { continue }
            let latestCommitNode = pullRequest.commits?.nodes?.compactMap { $0 }.last
            let state = latestCommitNode?.commit.statusCheckRollup?.state
            statuses[pullRequest.number] = PullRequestCIStatus(statusCheckRollupState: state)
        }
        return statuses
    }
}
