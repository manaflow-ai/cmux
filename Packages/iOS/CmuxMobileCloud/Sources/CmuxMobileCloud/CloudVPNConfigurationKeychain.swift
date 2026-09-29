#if swift(>=6.0)
public import Foundation
#else
import Foundation
#endif
import Security

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

    /// Stores a private configuration in the shared Keychain, replacing any
    /// existing value, and returns its persistent reference.
    public func store(_ configuration: String) throws -> Data {
        let data = Data(configuration.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.storage(added) }
        } else if status != errSecSuccess {
            throw Failure.storage(status)
        }
        var query = baseQuery
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var reference: CFTypeRef?
        let copied = SecItemCopyMatching(query as CFDictionary, &reference)
        guard copied == errSecSuccess, let reference = reference as? Data else {
            throw Failure.storage(copied)
        }
        return reference
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

    /// Deletes the configuration. Deleting a missing item succeeds.
    public func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.storage(status) }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "cloud-system-vpn",
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
