#if canImport(Security)
public import Foundation
import Security

/// Generic-password items in the host app's keychain access group.
public struct PhonePushKeychainStateStorage: PhonePushSharedStateStorage {
    static let service = "ai.manaflow.cmux.phone-push.shared-state"
    static let keychainAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    private let accessGroup: String?

    /// A nil group uses the process's default keychain group, which is the
    /// host group for both the app and its extension.
    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    /// Reads `CMUXKeychainAccessGroup`, which the app and the extension both
    /// expand to `TEAMID.<host bundle id>`. A value without a resolved team
    /// prefix (an unsigned build) returns nil rather than a group the
    /// signature cannot claim.
    public static func accessGroup(in bundle: Bundle) -> String? {
        accessGroup(from: bundle.object(forInfoDictionaryKey: "CMUXKeychainAccessGroup") as? String)
    }

    static func accessGroup(from raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("$("),
              let separator = value.firstIndex(of: "."),
              value.distance(from: value.startIndex, to: separator) == 10,
              value.index(after: separator) < value.endIndex
        else { return nil }
        return value
    }

    public func data(forKey key: String) -> Data? {
        let identity = itemQuery(forKey: key)
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              SecItemUpdate(
                  identity as CFDictionary,
                  [kSecAttrAccessible as String: Self.keychainAccessibility] as CFDictionary
              ) == errSecSuccess else { return nil }
        return data
    }

    public func setData(_ data: Data?, forKey key: String) {
        let query = itemQuery(forKey: key)
        guard let data else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.keychainAccessibility,
        ]
        guard SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound else {
            return
        }
        SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }

    public func keys(withPrefix prefix: String) -> [String] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
    }

    private func serviceQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func itemQuery(forKey key: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = key
        return query
    }
}
#endif
