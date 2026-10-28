public import Foundation

/// C1's JSON connector implementation. The app injects the authenticated request transport.
public struct CloudGitHubConnectorJSONClient: CloudGitHubConnectorClient, Sendable {
    public typealias Request = @Sendable (String, [String: String]) async throws -> Data

    private let request: Request

    public init(request: @escaping Request) {
        self.request = request
    }

    public init(transport: any CloudGitHubConnectorRequesting) {
        self.request = { path, query in try await transport.request(path: path, query: query) }
    }

    public func connectorStatuses() async throws -> [CloudConnectorStatus] {
        do {
            return try JSONDecoder().decode([CloudConnectorStatus].self, from: try await request("/v1/connectors", [:]))
        } catch {
            throw Self.map(error)
        }
    }

    public func installURL() async throws -> URL {
        struct Reply: Decodable { let url: String }
        do {
            let reply = try JSONDecoder().decode(Reply.self, from: try await request("/v1/connectors/github/install", [:]))
            guard let url = URL(string: reply.url) else { throw CloudGitHubConnectorClientError.requestFailed }
            return url
        } catch {
            throw Self.map(error)
        }
    }

    public func repositories(query: String, cursor: String?) async throws -> CloudGitHubRepositoryPage {
        var params = ["query": query]
        if let cursor { params["cursor"] = cursor }
        do {
            return try JSONDecoder().decode(CloudGitHubRepositoryPage.self, from: try await request("/v1/connectors/github/repos", params))
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: Error) -> CloudGitHubConnectorClientError {
        if let typed = error as? CloudGitHubConnectorClientError { return typed }
        if let transport = error as? URLError { return .classify(transport: transport) }
        return .requestFailed
    }
}

