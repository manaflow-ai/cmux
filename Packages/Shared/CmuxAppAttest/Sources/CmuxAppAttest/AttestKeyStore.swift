public import Foundation
import Security

/// Where an app keeps the id of its App Attest key (the key itself stays in
/// the Secure Enclave; the id is a handle, not a secret).
public protocol AttestKeyStore: Sendable {
    /// The stored key id, or nil.
    func load() -> String?
    /// Stores `keyID`, replacing any earlier one.
    func save(_ keyID: String)
    /// Forgets the stored key id.
    func delete()
}

/// ``AttestKeyStore`` in one generic-password item of the login keychain
/// (works without a provisioning profile on macOS).
///
/// ```swift
/// let store = KeychainAttestKeyStore(service: "com.cmuxterm.free-tier.app-attest", account: "key")
/// ```
public struct KeychainAttestKeyStore: AttestKeyStore {
    private let service: String
    private let account: String

    /// One item, named by `service` and `account`.
    /// - Parameter service: the item's service name.
    /// - Parameter account: the item's account name.
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ keyID: String) {
        let data = Data(keyID.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
