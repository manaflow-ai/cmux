import Foundation
import Security
import CryptoKit

/// Keeps v2 endpoint seeds in a dedicated keychain service scoped to the entire identity.
public actor V2IdentityKeyStore {
    private let service: String
    private let accessGroup: String?

    /// Creates a separate keychain namespace without inspecting legacy or Stack entries.
    /// - Parameters:
    ///   - applicationNamespace: The app bundle's explicit namespace.
    ///   - accessGroup: An optional signing-entitled keychain group for this app.
    public init(applicationNamespace: String, accessGroup: String? = nil) {
        service = applicationNamespace + ".cmux-iroh-v2.endpoint-keys"
        self.accessGroup = accessGroup
    }

    /// Loads or creates one key for an exact identity tuple.
    /// - Parameter identity: Environment, project, team, user, device, app namespace, and build tag.
    /// - Returns: The scope's stable v2 endpoint key.
    /// - Throws: A keychain or decoding error; never falls back to another scope.
    public func loadOrCreate(identity: V2Identity) throws -> V2IdentityKey {
        let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity))
        let account = digest.map { String(format: "%02x", $0) }.joined()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try V2IdentityKey(secretKey: data) }
        guard status == errSecItemNotFound else { throw V2ControlFailure.persistenceFailed }
        let key = V2IdentityKey()
        query[kSecValueData as String] = key.secretKey
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        if added == errSecDuplicateItem {
            // Another process may have created the same scope; use that committed key.
            let retry = SecItemCopyMatching(read as CFDictionary, &result)
            guard retry == errSecSuccess, let data = result as? Data else { throw V2ControlFailure.persistenceFailed }
            return try V2IdentityKey(secretKey: data)
        }
        guard added == errSecSuccess else { throw V2ControlFailure.persistenceFailed }
        return key
    }
}
