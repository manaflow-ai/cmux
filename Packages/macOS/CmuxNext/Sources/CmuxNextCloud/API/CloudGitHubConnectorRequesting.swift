public import Foundation

/// A transport seam for decoding C1's JSON without choosing a backend origin.
public protocol CloudGitHubConnectorRequesting: Sendable {
    func request(path: String, query: [String: String]) async throws -> Data
}
