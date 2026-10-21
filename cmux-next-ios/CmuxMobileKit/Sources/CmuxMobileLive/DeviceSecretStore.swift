import Foundation
import Security

/// Where this phone keeps its device secrets: the link and presence device
/// ids and the pairing keys' blobs (verify/persistence.md). The app uses the
/// Keychain; tests use memory.
/// The outcome of moving a Keychain item off its pre-rename service.
public enum LegacyMove: Sendable, Equatable {
    case moved, nothing, unreadable
}

public protocol DeviceSecretStore: Sendable {
    /// The item, or nil when there is none. Throws `OSStatus` failures other than not-found.
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String)
}

extension DeviceSecretStore {
    /// Moves an item to another account when the target has none (a one-time
    /// migration). Returns whether anything moved.
    @discardableResult
    func adopt(service: String, from legacy: String, to account: String) -> Bool {
        // Only when the target is known to be missing (a read error is not "missing").
        do {
            guard try read(service: service, account: account) == nil,
                  let data = try read(service: service, account: legacy) else { return false }
            try write(data, service: service, account: account)
        } catch {
            return false
        }
        delete(service: service, account: legacy)
        return true
    }

    /// Moves `account` from the `legacy` service to `service` when `service` has none (the
    /// one-time move off the pre-rename Keychain service).
    ///
    /// - Returns: `.unreadable` when either read failed (say before the first unlock): the
    ///   caller must not create a new item then, or it would shadow the one still waiting
    ///   under `legacy` for good.
    @discardableResult
    func adopt(from legacy: String, account: String, to service: String) -> LegacyMove {
        do {
            guard try read(service: service, account: account) == nil else { return .nothing }
            guard let data = try read(service: legacy, account: account) else { return .nothing }
            try write(data, service: service, account: account)
        } catch {
            return .unreadable
        }
        delete(service: legacy, account: account)
        return .moved
    }
}

/// The Keychain: generic passwords, this device only, readable after the
/// first unlock (a link is set up in the background too). Never synced, never
/// in a backup that restores onto another phone.
public struct KeychainSecretStore: DeviceSecretStore {
    public init() {}

    public struct Failure: Error, Equatable { public let status: OSStatus }

    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(service: String, account: String) throws -> Data? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return out as? Data
    }

    public func write(_ data: Data, service: String, account: String) throws {
        // Update in place, so a failed write never loses the item it replaces.
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(service, account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(service, account)
            q.merge(attributes) { $1 }
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete(service: String, account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

/// Tests: secrets in memory.
public final class MemorySecretStore: DeviceSecretStore, @unchecked Sendable { // crash-allow: lock-guarded
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    private func key(_ service: String, _ account: String) -> String { "\(service)\u{0}\(account)" }

    public func read(service: String, account: String) throws -> Data? {
        lock.withLock { items[key(service, account)] }
    }

    public func write(_ data: Data, service: String, account: String) throws {
        lock.withLock { items[key(service, account)] = data }
    }

    public func delete(service: String, account: String) {
        _ = lock.withLock { items.removeValue(forKey: key(service, account)) }
    }

    /// Every stored account of `service` (tests).
    public func accounts(service: String) -> [String] {
        lock.withLock {
            items.keys.compactMap { k in
                let parts = k.split(separator: "\u{0}", maxSplits: 1).map(String.init)
                return parts.count == 2 && parts[0] == service ? parts[1] : nil
            }.sorted()
        }
    }
}
