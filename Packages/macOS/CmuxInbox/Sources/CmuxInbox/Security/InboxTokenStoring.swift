public import Foundation

/// Secure token storage used by external inbox connectors.
public protocol InboxTokenStoring: Sendable {
    /// Saves token bytes for a source account.
    /// - Parameters:
    ///   - token: Secret token bytes. Implementations must not log or persist outside secure storage.
    ///   - source: Connector source.
    ///   - accountID: Source account id.
    func saveToken(_ token: Data, source: InboxSource, accountID: String) async throws

    /// Reads token bytes for a source account.
    /// - Parameters:
    ///   - source: Connector source.
    ///   - accountID: Source account id.
    /// - Returns: Token bytes or nil.
    func token(source: InboxSource, accountID: String) async throws -> Data?

    /// Deletes token bytes for a source account.
    /// - Parameters:
    ///   - source: Connector source.
    ///   - accountID: Source account id.
    func deleteToken(source: InboxSource, accountID: String) async throws

    /// Returns redacted credential state without exposing token bytes.
    /// - Parameters:
    ///   - source: Connector source.
    ///   - accountID: Source account id.
    func credentialState(source: InboxSource, accountID: String) async -> InboxCredentialState
}
