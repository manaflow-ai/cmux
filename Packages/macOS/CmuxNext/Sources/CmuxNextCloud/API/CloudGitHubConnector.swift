public import Foundation

/// The C1 connector operations used by Cloud setup and Auto.
///
/// The app supplies the authenticated implementation. A fake can implement this protocol in
/// tests, keeping the client independent of C1's deployment while the endpoint is dev-only.
public protocol CloudGitHubConnectorClient: Sendable {
    func connectorStatuses() async throws -> [CloudConnectorStatus]
    func installURL() async throws -> URL
    func repositories(query: String, cursor: String?) async throws -> CloudGitHubRepositoryPage
}
