public import Foundation

/// Token store that prefers a primary backend and degrades to a fallback.
///
/// Production composition uses Keychain as the primary store and the secure
/// file vault as the fallback, so linking works both in fully entitled release
/// builds and in tagged Debug builds where Keychain writes are rejected with
/// `errSecMissingEntitlement`. Reads consult the primary first so a credential
/// promoted into Keychain always wins; deletes clear both backends.
public actor InboxLayeredTokenStore: InboxTokenStoring {
    private let primary: any InboxTokenStoring
    private let fallback: any InboxTokenStoring

    /// Creates a layered store.
    /// - Parameters:
    ///   - primary: Preferred backend (typically Keychain).
    ///   - fallback: Backend used when the primary is unavailable.
    public init(primary: any InboxTokenStoring, fallback: any InboxTokenStoring) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Saves to the primary store, falling back when the primary rejects the write.
    public func saveToken(_ token: Data, source: InboxSource, accountID: String) async throws {
        do {
            try await primary.saveToken(token, source: source, accountID: accountID)
            // A stale fallback copy must not shadow future deletes from
            // resurrecting an old credential; clear it on primary success.
            try? await fallback.deleteToken(source: source, accountID: accountID)
        } catch {
            try await fallback.saveToken(token, source: source, accountID: accountID)
        }
    }

    /// Reads from the primary store first, then the fallback.
    public func token(source: InboxSource, accountID: String) async throws -> Data? {
        if let token = try? await primary.token(source: source, accountID: accountID) {
            return token
        }
        return try await fallback.token(source: source, accountID: accountID)
    }

    /// Deletes from both stores; missing entries are not an error.
    public func deleteToken(source: InboxSource, accountID: String) async throws {
        let primaryResult: Error?
        do {
            try await primary.deleteToken(source: source, accountID: accountID)
            primaryResult = nil
        } catch {
            primaryResult = error
        }
        try await fallback.deleteToken(source: source, accountID: accountID)
        // Surface a primary failure only if it may have left a credential behind.
        if let primaryResult, await primary.credentialState(source: source, accountID: accountID) == .present {
            throw primaryResult
        }
    }

    /// Present if either store holds the credential; inaccessible only when both are.
    public func credentialState(source: InboxSource, accountID: String) async -> InboxCredentialState {
        let primaryState = await primary.credentialState(source: source, accountID: accountID)
        if primaryState == .present { return primaryState }
        let fallbackState = await fallback.credentialState(source: source, accountID: accountID)
        if fallbackState == .present { return fallbackState }
        if primaryState == .inaccessible, fallbackState == .inaccessible { return .inaccessible }
        return .missing
    }
}
