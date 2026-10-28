import CmuxThreading
public import Foundation
import Security

/// Where an app keeps the id of its App Attest key (the key itself stays in
/// the Secure Enclave; the id is a handle, not a secret).
///
/// Every call reports a store error: a caller that cannot read or write the
/// key id must not make a new App Attest key (a new key spends the device's
/// monthly grant).
public protocol AttestKeyStore: Sendable {
    /// The stored key id, or nil when none is stored.
    /// - Throws: ``AttestKeyStoreError`` when the store cannot be read (for example a denied
    ///   Keychain access); the caller must then not make a new key.
    func load() throws -> String?
    /// Stores `keyID`, replacing any earlier one.
    /// - Throws: ``AttestKeyStoreError`` when the store cannot be written.
    func save(_ keyID: String) throws
    /// Forgets the stored key id (no error when none is stored).
    /// - Throws: ``AttestKeyStoreError`` when the store cannot be changed.
    func delete() throws
}

/// A key store read or write that failed, with the system status.
public struct AttestKeyStoreError: Error, Sendable, Equatable {
    /// The `OSStatus` of the failed call.
    public let status: Int32

    /// - Parameter status: the `OSStatus` of the failed call.
    public init(status: Int32) {
        self.status = status
    }

    /// The stored item exists but its content is not a key id (`errSecDecode`): the caller may
    /// replace it with one fresh key.
    public var isDamagedItem: Bool { status == errSecDecode }
}

/// ``AttestKeyStore`` in one generic-password item of the login keychain
/// (works without a provisioning profile on macOS). Each call waits for
/// securityd (and may show a Keychain prompt), so each is a checked blocking
/// call: run it off the main thread.
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

    public func load() throws -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = blockingCall(.systemCall) { SecItemCopyMatching(search as CFDictionary, &item) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AttestKeyStoreError(status: status) }
        guard let data = item as? Data, let keyID = String(data: data, encoding: .utf8), !keyID.isEmpty else {
            throw AttestKeyStoreError(status: errSecDecode)
        }
        return keyID
    }

    public func save(_ keyID: String) throws {
        let data = Data(keyID.utf8)
        let query = self.query
        let status = blockingCall(.systemCall) { () -> OSStatus in
            let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecItemNotFound else { return updated }
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AttestKeyStoreError(status: status) }
    }

    public func delete() throws {
        let query = self.query
        let status = blockingCall(.systemCall) { SecItemDelete(query as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AttestKeyStoreError(status: status) }
    }
}
