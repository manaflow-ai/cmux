public import CmuxNextCompat
public import Foundation
import Security

/// Generic password items under one service (`<bundle id>.device-hub`), for
/// this device only, never synced. A tagged build has its own bundle id and
/// so its own items; the Keychain trusts only the app that made an item.
public struct DeviceKeychain: Sendable {
    public let service: String
    /// Items in the data-protection keychain (`kSecUseDataProtectionKeychain`),
    /// as the app's other secrets: relay secrets. The device keys stay in the
    /// file keychain they were made in (moving them would make a new device).
    public let dataProtection: Bool
    /// The app's one guard of the Keychain UI switch.
    let loginKeychain: LoginKeychain

    public init(service: String, dataProtection: Bool = false, loginKeychain: LoginKeychain) {
        self.service = service
        self.dataProtection = dataProtection
        self.loginKeychain = loginKeychain
    }

    public func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        // No UI: an item another signature of this bundle id made is refused, never prompted for.
        let status = loginKeychain.withoutUI { SecItemCopyMatching(query as CFDictionary, &out) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DeviceIdentity.Failure.keychain(status) }
        return out as? Data
    }

    /// Adds or replaces the item.
    public func write(_ data: Data, account: String) throws {
        let update = loginKeychain.withoutUI { SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw DeviceIdentity.Failure.keychain(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceIdentity.Failure.keychain(status) }
    }

    /// Every account under this service (empty when none or unreadable).
    public func accounts() -> [String] {
        var query = query("")
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard loginKeychain.withoutUI({ SecItemCopyMatching(query as CFDictionary, &out) }) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func delete(_ account: String) throws {
        let status = loginKeychain.withoutUI { SecItemDelete(query(account) as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceIdentity.Failure.keychain(status) }
    }

    func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
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
