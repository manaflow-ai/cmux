public import Foundation
import Security

/// The production Security.framework implementation of ``V2KeychainAccess``.
public struct V2SystemKeychainAccess: V2KeychainAccess, Sendable {
    private static let migrationMarker = "cmux.v2.keychain.migration-complete"

    /// Whether this platform exposes a separate file-keychain domain.
    public let supportsLegacyFileKeychain: Bool

    /// Creates the system keychain adapter.
    public init() {
        #if os(macOS)
        supportsLegacyFileKeychain = true
        #else
        supportsLegacyFileKeychain = false
        #endif
    }

    /// Reads the exact marker metadata without changing item identity fields.
    public func hasMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Bool {
        var query = baseQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess, let attributes = result as? NSDictionary else {
            throw V2KeychainAccessError.status(status)
        }
        return attributes[kSecAttrComment] as? String == Self.migrationMarker
    }

    /// Updates only the fixed marker metadata on an existing primary item.
    public func setMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        let status = SecItemUpdate(
            baseQuery(
                service: service,
                account: account,
                accessGroup: accessGroup,
                dataProtection: dataProtection
            ) as CFDictionary,
            [kSecAttrComment as String: Self.migrationMarker] as CFDictionary
        )
        guard status == errSecSuccess else { throw V2KeychainAccessError.status(status) }
    }

    /// Reads an exact generic-password item from the selected keychain domain.
    public func read(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Data? {
        var query = baseQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw V2KeychainAccessError.status(status)
        }
        return data
    }

    /// Adds an exact generic-password item to the selected keychain domain.
    public func add(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        var query = baseQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw V2KeychainAccessError.duplicate }
        guard status == errSecSuccess else { throw V2KeychainAccessError.status(status) }
    }

    /// Deletes an exact generic-password item from the selected keychain domain.
    public func delete(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        let status = SecItemDelete(
            baseQuery(
                service: service,
                account: account,
                accessGroup: accessGroup,
                dataProtection: dataProtection
            ) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw V2KeychainAccessError.status(status)
        }
    }

    private func baseQuery(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Endpoint seeds and installation IDs must never be iCloud-synced.
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
