struct GitHubPullRequestCIStatusGraphQLPullRequest: Decodable, Sendable {
    let number: Int
    let commits: GitHubPullRequestCIStatusGraphQLCommitConnection?
}
