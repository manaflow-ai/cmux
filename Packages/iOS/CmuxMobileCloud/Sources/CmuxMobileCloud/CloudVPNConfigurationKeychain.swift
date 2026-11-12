#if swift(>=6.0)
public import Foundation
public import Security
#else
import Foundation
import Security
#endif

/// The system VPN's wg-quick configuration, shared by the app and the packet
/// tunnel extension through their common Keychain group.
///
/// Network Extension preferences hold only the opaque persistent reference
/// this returns, never the configuration, because the configuration carries
/// the VPN peer's private key. The item never leaves the device. The
/// extension compiles this file directly, so it depends on nothing else in
/// the package.
public struct CloudVPNConfigurationKeychain: Sendable {
    /// Keychain failures. Deliberately carries no item contents.
    public enum Failure: Error, Sendable, Equatable {
        /// The Keychain operation returned this status.
        case storage(OSStatus)
    }

    private let service: String
    private let accessGroup: String?

    /// - Parameters:
    ///   - service: The item's service, unique per app bundle.
    ///   - accessGroup: The Keychain group the app and extension share; nil
    ///     uses the caller's default group.
    public init(service: String, accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// Stores a private configuration in a fresh shared Keychain item and
    /// returns its persistent reference.
    public func store(_ configuration: String) throws -> Data {
        let data = Data(configuration.utf8)
        let account = "cloud-system-vpn-\(UUID().uuidString)"
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.storage(added) }

        var query = baseQuery(account: account)
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var reference: CFTypeRef?
        let copied = SecItemCopyMatching(query as CFDictionary, &reference)
        guard copied == errSecSuccess, let reference = reference as? Data else {
            _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
            throw Failure.storage(copied)
        }
        return reference
    }

    /// Deletes a configuration through the persistent reference saved in
    /// Network Extension preferences.
    public func remove(reference: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecValuePersistentRef as String: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.storage(status)
        }
    }

    /// Reads a configuration through its persistent reference. The packet
    /// tunnel calls this with the reference saved in its preferences.
    public static func read(reference: Data) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecValuePersistentRef as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess,
              let data = value as? Data,
              let configuration = String(data: data, encoding: .utf8) else {
            throw Failure.storage(status)
        }
        return configuration
    }

    /// Deletes every configuration in this service. Deleting missing items
    /// succeeds, including generated candidate items with unique accounts.
    public func remove() throws {
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.storage(status) }
    }

    private func baseQuery(account: String? = "cloud-system-vpn") -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
