struct GitHubPullRequestCIStatusGraphQLResponse: Decodable, Sendable {
    let data: GitHubPullRequestCIStatusGraphQLData?
    let errors: [GitHubPullRequestCIStatusGraphQLError]

    private enum CodingKeys: String, CodingKey {
        case data, errors
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(GitHubPullRequestCIStatusGraphQLData.self, forKey: .data)
        errors = try container.decodeIfPresent([GitHubPullRequestCIStatusGraphQLError].self, forKey: .errors) ?? []
    }

    var ciStatusesByPullRequestNumber: [Int: PullRequestCIStatus] {
        var statuses: [Int: PullRequestCIStatus] = [:]
        guard let pullRequests = data?.repository?.pullRequestsByAlias.values else {
            return statuses
        }
        for pullRequest in pullRequests {
            guard let pullRequest else {
                continue
            }
            let latestCommitNode = pullRequest.commits?.nodes.compactMap { $0 }.last
            let state = latestCommitNode?.commit.statusCheckRollup?.state
            statuses[pullRequest.number] = PullRequestCIStatus(statusCheckRollupState: state)
        }
        return statuses
    }
}
