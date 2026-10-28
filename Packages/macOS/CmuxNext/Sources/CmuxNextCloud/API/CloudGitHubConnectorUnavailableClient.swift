public import Foundation

/// A closed client for builds where C1 is not wired yet. It fails closed and never opens a URL.
public struct CloudGitHubConnectorUnavailableClient: CloudGitHubConnectorClient, Sendable {
    public init() {}

    public func connectorStatuses() async throws -> [CloudConnectorStatus] {
        throw CloudGitHubConnectorClientError.unavailable
    }

    public func installURL() async throws -> URL {
        throw CloudGitHubConnectorClientError.unavailable
    }

    public func repositories(query: String, cursor: String?) async throws -> CloudGitHubRepositoryPage {
        throw CloudGitHubConnectorClientError.unavailable
    }
}

