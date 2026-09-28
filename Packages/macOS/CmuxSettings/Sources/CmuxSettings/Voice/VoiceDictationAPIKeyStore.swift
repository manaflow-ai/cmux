public import Foundation
#if canImport(Security)
import Security
#endif

/// Keeps the OpenAI API key for cloud dictation in the login Keychain.
///
/// The key is never written to `UserDefaults` or `cmux.json`. Settings saves
/// and removes it; the dictation engine reads it at session start. The
/// Keychain accessors are injected so tests run against an in-memory fake.
public struct VoiceDictationAPIKeyStore: Sendable {
    /// Posted after the key is saved or removed.
    public static let didChangeNotification = Notification.Name("cmux.voiceDictationAPIKeyDidChange")

    static let service = "com.cmuxterm.app.voice-dictation"
    static let account = "openai-api-key"

    private let load: @Sendable () -> String?
    private let store: @Sendable (String?) -> Bool

    /// Creates a store backed by the login Keychain.
    public init() {
        self.init(
            load: { Self.loadFromKeychain() },
            store: { Self.storeInKeychain($0) }
        )
    }

    /// Creates a store with explicit accessors, for testing.
    ///
    /// - Parameters:
    ///   - load: Reads the saved key.
    ///   - store: Saves a key, or deletes it when passed `nil`. Returns
    ///     whether the write succeeded.
    public init(
        load: @escaping @Sendable () -> String?,
        store: @escaping @Sendable (String?) -> Bool
    ) {
        self.load = load
        self.store = store
    }

    /// The saved key, or `nil` when none is saved.
    public func apiKey() -> String? {
        guard let key = load()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// Whether a key is saved.
    public var hasAPIKey: Bool { apiKey() != nil }

    /// Saves `key`, trimmed. An empty key removes the saved one.
    ///
    /// - Returns: Whether the Keychain write succeeded.
    @discardableResult
    public func setAPIKey(_ key: String?) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded = store(trimmed?.isEmpty == false ? trimmed : nil)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return succeeded
    }

    private static func baseQuery() -> [String: Any] {
        #if canImport(Security)
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #else
        return [:]
        #endif
    }

    private static func loadFromKeychain() -> String? {
        #if canImport(Security)
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    private static func storeInKeychain(_ key: String?) -> Bool {
        #if canImport(Security)
        let query = baseQuery()
        guard let key else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(key.utf8)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }
}
