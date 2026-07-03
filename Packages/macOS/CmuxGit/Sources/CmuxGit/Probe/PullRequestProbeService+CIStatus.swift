import Foundation

extension PullRequestProbeService {
    /// Fetches CI rollups for exact open PR numbers with one token-gated GraphQL request.
    nonisolated func pullRequestCIStatusesByNumber(
        repoSlug: String,
        pullRequestNumbers: Set<Int>,
        session: URLSession,
        authHeader: String?
    ) async -> [Int: PullRequestCIStatus]? {
        guard let authHeader, !authHeader.isEmpty else {
            return [:]
        }
        let numbers = pullRequestNumbers.filter { $0 > 0 }.sorted()
        guard !numbers.isEmpty else {
            return [:]
        }
        guard let repository = Self.repositoryParts(repoSlug: repoSlug) else {
            return nil
        }

        let fields = numbers.enumerated().map { index, number in
            """
                pr\(index): pullRequest(number: \(number)) {
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
            """
        }.joined(separator: "\n")
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
        \(fields)
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

    /// Open pull-request numbers that are actually needed for the current candidate branches.
    nonisolated static func openPullRequestNumbers(
        in entry: WorkspacePullRequestRepoCacheEntry,
        candidateBranches: Set<String>
    ) -> Set<Int> {
        Set(candidateBranches.compactMap { branch in
            guard let pullRequest = entry.pullRequestsByBranch[branch],
                  PullRequestStatus(githubState: pullRequest.state) == .open else {
                return nil
            }
            return pullRequest.number
        })
    }

    /// Completes a repo cache entry's CI coverage for requested PR numbers.
    nonisolated func repoCacheEntry(
        _ cacheEntry: WorkspacePullRequestRepoCacheEntry,
        repoSlug: String,
        fetchTimestamp: Date,
        session: URLSession,
        authHeader: String?,
        includeCIStatus: Bool,
        pullRequestNumbers: Set<Int>
    ) async -> WorkspacePullRequestRepoCacheEntry {
        guard includeCIStatus else {
            return cacheEntry
        }

        let requestedNumbers = Set(pullRequestNumbers.filter { $0 > 0 })
        var ciStatusesByNumber = cacheEntry.includesCIStatus
            ? cacheEntry.ciStatusByPullRequestNumber
            : [:]
        let missingNumbers = requestedNumbers.subtracting(ciStatusesByNumber.keys)
        if !missingNumbers.isEmpty {
            let fetchedStatuses = await pullRequestCIStatusesByNumber(
                repoSlug: repoSlug,
                pullRequestNumbers: missingNumbers,
                session: session,
                authHeader: authHeader
            ) ?? [:]
            for number in missingNumbers {
                ciStatusesByNumber[number] = fetchedStatuses[number] ?? .neutral
            }
        }

        return Self.repoCacheEntry(
            cacheEntry,
            applyingCIStatuses: ciStatusesByNumber,
            fetchedAt: fetchTimestamp
        )
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
        includeCIStatus: Bool,
        pullRequestNumbers: Set<Int> = []
    ) -> Bool {
        guard now.timeIntervalSince(entry.fetchedAt) < Self.repoCacheLifetime else {
            return false
        }
        guard includeCIStatus else {
            return true
        }
        guard entry.includesCIStatus else {
            return false
        }
        let requestedNumbers = Set(pullRequestNumbers.filter { $0 > 0 })
        return requestedNumbers.isSubset(of: Set(entry.ciStatusByPullRequestNumber.keys))
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
        let pullRequestsByAlias: [String: PullRequestNode?]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            var pullRequestsByAlias: [String: PullRequestNode?] = [:]
            for key in container.allKeys {
                pullRequestsByAlias[key.stringValue] = try container.decodeIfPresent(
                    PullRequestNode.self,
                    forKey: key
                )
            }
            self.pullRequestsByAlias = pullRequestsByAlias
        }
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
        guard let pullRequests = data?.repository?.pullRequestsByAlias.values else {
            return statuses
        }
        for pullRequest in pullRequests {
            guard let pullRequest else {
                continue
            }
            let latestCommitNode = pullRequest.commits?.nodes?.compactMap { $0 }.last
            let state = latestCommitNode?.commit.statusCheckRollup?.state
            statuses[pullRequest.number] = PullRequestCIStatus(statusCheckRollupState: state)
        }
        return statuses
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
