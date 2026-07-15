public import Foundation
import Security

/// Device-only Keychain storage for Iroh EndpointID secret material.
public final class CmxIrohKeychainIdentityStore: CmxIrohSecureIdentityStoring, @unchecked Sendable {
    private let service: String

    /// Creates a Keychain store isolated by service name.
    ///
    /// - Parameter service: The generic-password service identifier.
    public init(service: String = "com.cmuxterm.iroh.endpoint-identity.v1") {
        self.service = service
    }

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
            throw CmxIrohKeychainIdentityStoreError(status: status)
        }
        return data
    }

    public func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CmxIrohKeychainIdentityStoreError(status: updateStatus)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CmxIrohKeychainIdentityStoreError(status: addStatus)
        }
    }

    public func delete(account: String) throws {
        try delete(query: baseQuery(account: account))
    }

    public func deleteAll() throws {
        try delete(query: baseQuery())
    }

    /// Generates one Ed25519 secret using Security.framework.
    public static func randomSecretBytes() throws -> Data {
        let count = 32
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CmxIrohIdentityRepositoryError.randomGenerationFailed(status)
        }
        return data
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

    private func delete(query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CmxIrohKeychainIdentityStoreError(status: status)
        }
    }
}
