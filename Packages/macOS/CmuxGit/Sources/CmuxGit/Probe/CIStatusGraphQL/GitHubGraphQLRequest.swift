struct GitHubGraphQLRequest: Encodable {
    let query: String
    let variables: [String: String]
}
