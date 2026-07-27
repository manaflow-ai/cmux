public import Foundation
import Security

/// Device-only Keychain storage for Iroh relay capabilities.
public actor CmxIrohKeychainCredentialStore: CmxIrohSecureCredentialStoring {
    private let service: String

    /// Creates a Keychain store isolated by service name.
    ///
    /// - Parameter service: The generic-password service identifier.
    public init(service: String = "com.cmuxterm.iroh.relay-credentials.v1") {
        self.service = service
    }

    /// Loads one opaque-scope capability from Keychain.
    ///
    /// - Parameter account: The repository-derived scope.
    /// - Returns: The stored capability, or `nil` when none exists.
    /// - Throws: ``CmxIrohKeychainCredentialStoreError`` when Keychain fails.
    public func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CmxIrohKeychainCredentialStoreError(status: status)
        }
        return data
    }

    /// Upserts one opaque-scope capability with the requested data protection.
    ///
    /// - Parameters:
    ///   - data: The encoded capability.
    ///   - account: The repository-derived scope.
    ///   - accessibility: The required data-protection policy.
    /// - Throws: ``CmxIrohKeychainCredentialStoreError`` when Keychain fails.
    public func write(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility
    ) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: secAccessibility(accessibility),
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CmxIrohKeychainCredentialStoreError(status: updateStatus)
        }

        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw CmxIrohKeychainCredentialStoreError(status: addStatus)
        }
        let retryStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        guard retryStatus == errSecSuccess else {
            throw CmxIrohKeychainCredentialStoreError(status: retryStatus)
        }
    }

    /// Removes one opaque-scope capability from Keychain.
    ///
    /// - Parameter account: The repository-derived scope.
    /// - Throws: ``CmxIrohKeychainCredentialStoreError`` when Keychain fails.
    public func delete(account: String) throws {
        try delete(query: baseQuery(account: account))
    }

    /// Removes every relay capability owned by this Keychain service.
    ///
    /// - Throws: ``CmxIrohKeychainCredentialStoreError`` when Keychain fails.
    public func deleteAll() throws {
        try delete(query: baseQuery())
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private func secAccessibility(
        _ accessibility: CmxIrohSecureCredentialAccessibility
    ) -> CFString {
        switch accessibility {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    private func delete(query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CmxIrohKeychainCredentialStoreError(status: status)
        }
    }
}
