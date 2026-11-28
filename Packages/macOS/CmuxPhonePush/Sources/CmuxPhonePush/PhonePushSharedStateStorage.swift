public import Foundation
import Security

/// Storage for push state that the iOS host app writes and its notification
/// service extension reads: the active account and pinned Mac keys.
///
/// The two processes see the same data only through a container both
/// signatures grant. The App Group is absent from the release host App IDs
/// (INTERNAL, BETA, App Store) and from API-key-signed development builds, so
/// an App Group suite silently falls back to a per-process store there and the
/// extension can never decrypt. Every signing lane grants both targets the
/// host's keychain access group, which is what iOS uses.
public protocol PhonePushSharedStateStorage {
    func data(forKey key: String) -> Data?
    /// Stores `data`, or removes the value when `data` is nil.
    func setData(_ data: Data?, forKey key: String)
    func keys(withPrefix prefix: String) -> [String]
}

extension Bundle {
    /// The keychain on iOS, scoped by this bundle's host access group; the
    /// Mac has no extension and keeps its existing process-local defaults.
    public var phonePushSharedStateStorage: any PhonePushSharedStateStorage {
        #if os(iOS)
        PhonePushKeychainStateStorage(
            accessGroup: PhonePushKeychainStateStorage.accessGroup(in: self)
        )
        #else
        PhonePushUserDefaultsStateStorage(defaults: .standard)
        #endif
    }
}

/// Generic-password items in the host app's keychain access group.
public struct PhonePushKeychainStateStorage: PhonePushSharedStateStorage {
    static let service = "ai.manaflow.cmux.phone-push.shared-state"

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
        var query = itemQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func setData(_ data: Data?, forKey key: String) {
        let query = itemQuery(forKey: key)
        guard let data else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
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

/// Process-local defaults, used by the Mac.
public struct PhonePushUserDefaultsStateStorage: PhonePushSharedStateStorage {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        switch defaults.object(forKey: key) {
        case let data as Data:
            data
        // The peer-key registry was stored as a string array before this
        // storage existed; read it so existing Mac pins keep their order.
        case let strings as [String]:
            try? JSONEncoder().encode(strings)
        default:
            nil
        }
    }

    public func setData(_ data: Data?, forKey key: String) {
        defaults.set(data, forKey: key)
    }

    public func keys(withPrefix prefix: String) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    }
}
