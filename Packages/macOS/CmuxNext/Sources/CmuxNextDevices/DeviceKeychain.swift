public import Foundation
import Security

/// Generic password items under one service (`<bundle id>.device-hub`), for
/// this device only, never synced. A tagged build has its own bundle id and
/// so its own items; the Keychain trusts only the app that made an item.
public struct DeviceKeychain: Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DeviceIdentity.Failure.keychain(status) }
        return out as? Data
    }

    /// Adds or replaces the item.
    public func write(_ data: Data, account: String) throws {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw DeviceIdentity.Failure.keychain(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceIdentity.Failure.keychain(status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceIdentity.Failure.keychain(status) }
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    /// Secure Enclave key use without a user-presence prompt, after first unlock, this device only.
    static func keyAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                           .privateKeyUsage, &error) else {
            throw DeviceIdentity.Failure.keychain(errSecParam)
        }
        return access
    }
}
