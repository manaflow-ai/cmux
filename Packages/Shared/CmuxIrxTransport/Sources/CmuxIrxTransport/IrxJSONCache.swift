public import Foundation
import Security

/// Synchronous JSON cache seam behind the broker's persisted state
/// (binding / trust / relay-credentials / grants). Synchronous by contract:
/// `IrxBrokerService.init` reads the binding cache to arm request signing
/// before any async context exists, and the admission path reads trust with
/// no actor hop.
public protocol IrxJSONCache<Value>: Sendable {
    associatedtype Value: Codable & Sendable
    func load() -> Value?
    @discardableResult func save(_ value: Value) -> Bool
    func clear()
}

extension IrxDiskCache: IrxJSONCache {}

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
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    @discardableResult
    public func save(_ value: Value) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return load() != nil }
        guard updateStatus == errSecItemNotFound else { return false }
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
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

/// One-way, idempotent file-to-primary migration: the first load that finds
/// the primary empty but a legacy file present copies the value into the
/// primary and deletes the file. Every later read is primary-only, and a
/// resurrected legacy file is ignored while the primary holds a value.
public struct IrxMigratingJSONCache<
    Primary: IrxJSONCache, Legacy: IrxJSONCache
>: IrxJSONCache, Sendable where Primary.Value == Legacy.Value {
    public typealias Value = Primary.Value

    private let primary: Primary
    private let legacy: Legacy

    public init(primary: Primary, legacy: Legacy) {
        self.primary = primary
        self.legacy = legacy
    }

    public func load() -> Value? {
        if let value = primary.load() { return value }
        guard let migrated = legacy.load() else { return nil }
        // Keep the legacy copy when the primary is unavailable. Keychain
        // writes can fail while the device is locked or entitlements are
        // misconfigured; deleting the only readable copy would make the
        // account unrecoverable on the next launch.
        guard primary.save(migrated) else { return migrated }
        legacy.clear()
        return migrated
    }

    @discardableResult
    public func save(_ value: Value) -> Bool {
        guard primary.save(value) else { return false }
        // A save supersedes anything the legacy file held; drop it so a
        // later primary clear can never resurrect stale state.
        legacy.clear()
        return true
    }

    public func clear() {
        primary.clear()
        legacy.clear()
    }
}

/// Scope identifiers for the Release keychain caches. Threaded through
/// ``IrxBrokerService/Configuration`` because the keychain account is
/// `<kind>|<accountID>|<backendHost>` and neither identifier is derivable
/// from the cache directory alone.
public struct IrxBrokerCacheScope: Sendable, Equatable {
    public var accountID: String
    public var backendHost: String
    public var keychainAccessGroup: String?

    public init(
        accountID: String,
        backendHost: String,
        keychainAccessGroup: String? = nil
    ) {
        self.accountID = accountID
        self.backendHost = backendHost
        self.keychainAccessGroup = keychainAccessGroup
    }
}

enum IrxBrokerCacheFactory {
    /// DEBUG: the byte-identical JSON file (dev tooling reads the state dir).
    /// Release: keychain-backed when the signed-in account scope is known.
    /// Unscoped legacy files are retained but never imported: their old format
    /// has no account/backend owner, so migration could hand one account
    /// another account's binding or credentials. Before identity is known, the
    /// file remains the temporary store.
    static func make<Value: Codable & Sendable>(
        kind: String,
        fileURL: URL,
        scope: IrxBrokerCacheScope?
    ) -> any IrxJSONCache<Value> {
        let file = IrxDiskCache<Value>(fileURL: fileURL)
        #if DEBUG
        return file
        #else
        guard let scope else { return file }
        // A legacy snapshot is not account/backend scoped. Never import it
        // into the scoped keychain item, even when its shape happens to decode.
        // Preserve the old copy until an explicit, identity-validated
        // migration can replace it; construction must never destroy the only
        // offline binding or credential state during an upgrade.
        return IrxKeychainJSONCache<Value>(
            account: "\(kind)|\(scope.accountID)|\(scope.backendHost)",
            accessGroup: scope.keychainAccessGroup
        )
        #endif
    }
}
