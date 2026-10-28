public import Foundation

/// One page from `GET /v1/connectors/github/repos`.
public struct CloudGitHubRepositoryPage: Codable, Equatable, Sendable {
    public let repos: [CloudGitHubRepository]
    public let cursor: String?

    public init(repos: [CloudGitHubRepository], cursor: String? = nil) {
        self.repos = repos
        self.cursor = cursor
    }
}
