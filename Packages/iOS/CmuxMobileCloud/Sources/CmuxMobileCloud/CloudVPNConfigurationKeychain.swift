public import Foundation
import Security

/// Shared by the app and packet provider. Only an opaque Keychain reference
/// goes in Network Extension preferences; the private config is device-only.
public struct CloudVPNConfigurationKeychain: Sendable {
    private let service: String
    private let accessGroup: String

    public init(service: String, accessGroup: String) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func store(_ configuration: String) throws -> Data {
        let query = baseQuery
        let data = Data(configuration.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw Failure.storage }
        } else if status != errSecSuccess {
            throw Failure.storage
        }
        var referenceQuery = query
        referenceQuery[kSecReturnPersistentRef as String] = true
        referenceQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var reference: CFTypeRef?
        guard SecItemCopyMatching(referenceQuery as CFDictionary, &reference) == errSecSuccess,
              let reference = reference as? Data else { throw Failure.storage }
        return reference
    }

    public static func read(reference: Data) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecValuePersistentRef as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data,
              let config = String(data: data, encoding: .utf8) else { throw Failure.storage }
        return config
    }

    public func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.storage }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "cloud-system-vpn",
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    private enum Failure: Error { case storage }
}
