public import Foundation
import Security

/// Keychain-backed token vault for live integrations.
public actor InboxKeychainTokenVault: InboxTokenStoring {
    private let service: String

    /// Creates a token vault.
    /// - Parameter service: Keychain service name.
    public init(service: String = "com.cmuxterm.app.integrations") {
        self.service = service
    }

    /// Saves token bytes using an update-then-add SecItem pattern.
    public func saveToken(_ token: Data, source: InboxSource, accountID: String) async throws {
        let query = baseQuery(source: source, accountID: accountID)
        let update: [String: Any] = [
            kSecValueData as String: token,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = token
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecUseDataProtectionKeychain as String] = true
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw InboxError.credentialStoreFailed("Keychain save failed (\(status))")
        }
    }

    /// Reads token bytes from Keychain.
    public func token(source: InboxSource, accountID: String) async throws -> Data? {
        var query = baseQuery(source: source, accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw InboxError.credentialStoreFailed("Keychain read failed (\(status))")
        }
        return result as? Data
    }

    /// Deletes token bytes for the exact source account.
    public func deleteToken(source: InboxSource, accountID: String) async throws {
        let status = SecItemDelete(baseQuery(source: source, accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw InboxError.credentialStoreFailed("Keychain delete failed (\(status))")
        }
    }

    /// Returns redacted token state without loading token data into socket payloads.
    public func credentialState(source: InboxSource, accountID: String) async -> InboxCredentialState {
        var query = baseQuery(source: source, accountID: accountID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess { return .present }
        if status == errSecItemNotFound { return .missing }
        return .inaccessible
    }

    private func baseQuery(source: InboxSource, accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(source.rawValue):\(accountID)",
        ]
    }
}
