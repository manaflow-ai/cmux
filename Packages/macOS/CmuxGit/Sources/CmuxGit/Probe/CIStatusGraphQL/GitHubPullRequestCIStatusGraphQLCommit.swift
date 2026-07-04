struct GitHubPullRequestCIStatusGraphQLCommit: Decodable, Sendable {
    let statusCheckRollup: GitHubPullRequestCIStatusGraphQLStatusCheckRollup?
}
