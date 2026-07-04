struct GitHubPullRequestCIStatusGraphQLCommitConnection: Decodable, Sendable {
    let nodes: [GitHubPullRequestCIStatusGraphQLCommitNode?]

    private enum CodingKeys: String, CodingKey {
        case nodes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([GitHubPullRequestCIStatusGraphQLCommitNode?].self, forKey: .nodes) ?? []
    }
}
