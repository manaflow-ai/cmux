struct GitHubPullRequestCIStatusGraphQLRepository: Decodable, Sendable {
    let pullRequestsByAlias: [String: GitHubPullRequestCIStatusGraphQLPullRequest?]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GitHubGraphQLDynamicCodingKey.self)
        var pullRequestsByAlias: [String: GitHubPullRequestCIStatusGraphQLPullRequest?] = [:]
        for key in container.allKeys {
            pullRequestsByAlias[key.stringValue] = try container.decodeIfPresent(
                GitHubPullRequestCIStatusGraphQLPullRequest.self,
                forKey: key
            )
        }
        self.pullRequestsByAlias = pullRequestsByAlias
    }
}
