#if canImport(Security)
public import Foundation
import Security

/// Keychain-backed JSON cache for Release builds.
///
/// Mirrors ``CmxIrohKeychainCredentialStore``'s exact item shape (device-only
/// generic password, data-protection keychain, AfterFirstUnlockThisDeviceOnly,
/// optional access group) but through synchronous SecItem calls, because the
/// broker's init-time signing arm and the admission path cannot await an
/// actor. RECONCILE: if the shared store ever grows a synchronous facade,
/// fold this onto it.
public struct IrxKeychainJSONCache<Value: Codable & Sendable>: IrxJSONCache {
    public static var service: String { "com.cmuxterm.irx.cache.v1" }

    private let account: String
    private let accessGroup: String?

    /// - Parameter account: `"<kind>|<accountID>|<backendHost>"`, so one
    ///   keychain service hosts every cache kind without collisions across
    ///   accounts or environments.
    public init(account: String, accessGroup: String? = nil) {
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() -> Value? {
        var query: [String: Any] = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        // SAFETY: SecItemCopyMatching stores at most one +1 CFTypeRef in the local
        // `result`, live for this call; the Swift import takes ownership of it.
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    @discardableResult
    public func save(_ value: Value) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let query: [String: Any] = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return load() != nil }
        guard updateStatus == errSecItemNotFound else { return false }
        var insert: [String: Any] = query
        attributes.forEach { insert[$0.key] = $0.value }
        // SAFETY: with a nil result pointer SecItemAdd writes nothing back.
        let addStatus = unsafe SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecSuccess { return load() != nil }
        if addStatus == errSecDuplicateItem {
            let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            return retry == errSecSuccess && load() != nil
        }
        return false
    }

    public func clear() {
        _ = SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
#endif
