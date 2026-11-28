import Foundation
import Security

/// API keys the user pastes into the Accounts screen. They go to the
/// Keychain (this store) or to CodeRouter, never to cmux.json or a log.
public protocol ProviderKeyStoring: Sendable {
    /// Providers with a saved key (attributes only, no secret read).
    func savedProviders() -> Set<AIProvider>
    func save(_ key: String, for provider: AIProvider) throws
    /// The saved key, read only to send it to CodeRouter on an explicit Connect.
    func key(for provider: AIProvider) throws -> String?
    func delete(for provider: AIProvider) throws
}

public struct ProviderKeyStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: Int32
    public var description: String { "Keychain error \(status)" }
}

/// One generic-password item per provider under `service` (default
/// `<bundle id>.ai-provider-keys`), account = the provider id.
/// Accessible after first unlock, this device only.
public struct KeychainProviderKeyStore: ProviderKeyStoring {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public static func service(bundleID: String?) -> String {
        "\(bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app").ai-provider-keys"
    }

    private func base(_ provider: AIProvider?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let provider { query[kSecAttrAccount as String] = provider.rawValue }
        return query
    }

    public func savedProviders() -> Set<AIProvider> {
        var query = base(nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = NoPromptContext.make()
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return Set(items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(AIProvider.init(rawValue:)) })
    }

    public func save(_ key: String, for provider: AIProvider) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(base(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(provider)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "cmux \(provider.displayName) API key"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw ProviderKeyStoreError(status: added) }
        } else if status != errSecSuccess {
            throw ProviderKeyStoreError(status: status)
        }
    }

    public func key(for provider: AIProvider) throws -> String? {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ProviderKeyStoreError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func delete(for provider: AIProvider) throws {
        let status = SecItemDelete(base(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProviderKeyStoreError(status: status) }
    }
}
