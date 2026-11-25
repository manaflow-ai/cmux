#if canImport(Security)
public import Foundation
import Security

/// The phone's tailnet keys (the in-app userspace node, `cmux-mobile-tailnet`): the platform glue
/// for its Rust `key::KeyStore`. The item's attributes are decided in Rust (`key::keychain_item`)
/// and tested there; this store only writes what they say.
///
/// - The app's own Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronized:
///   no iCloud Keychain, no restore onto another phone.
/// - One generic-password item per tailnet: service `dev.cmux.tailnet`, account the login server's
///   host (or `tailscale`).
/// - Forget deletes the item; the caller logs the node out in the same action.
/// - The key never reaches a log or `description`.
public struct TailnetKeyStore: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case keychain(OSStatus)
        case notText
    }

    public static let service = "dev.cmux.tailnet"

    private let service: String

    public init(service: String = TailnetKeyStore.service) {
        self.service = service
    }

    /// Saves (or replaces) the key for `tailnet`.
    public func save(_ key: String, tailnet: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(
            query(tailnet) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure.keychain(status) }
        var add = query(tailnet)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.keychain(added) }
    }

    /// The key for `tailnet`, or nil when none is saved.
    public func load(tailnet: String) throws -> String? {
        var read = query(tailnet)
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = out as? Data, let text = String(data: data, encoding: .utf8) else {
            throw Failure.notText
        }
        return text
    }

    /// Forget: deletes the key for `tailnet`. Deleting a missing key succeeds.
    public func delete(tailnet: String) throws {
        let status = SecItemDelete(query(tailnet) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    private func query(_ tailnet: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tailnet,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
#endif
