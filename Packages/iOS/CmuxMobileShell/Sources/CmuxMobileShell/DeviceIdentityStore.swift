import Foundation
import Security

/// The outcome of reading the persisted device id.
///
/// Distinguishing "no id yet" from "cannot read the store right now" is the
/// whole point. Collapsing both to `nil` makes a locked-Keychain read (a
/// background launch before the device's first unlock, when an
/// `AfterFirstUnlock` item is unreadable) look identical to a fresh install, so
/// the caller mints a NEW id and strands the phone's existing `(user, device,
/// tag)` binding — the exact failure this store exists to prevent.
/// `.unavailable` lets the caller fail closed instead of re-minting.
enum DeviceIdentityReadResult: Equatable, Sendable {
    /// A persisted id was read successfully.
    case found(String)
    /// The store is readable and holds no id (genuine first run / not migrated).
    case absent
    /// The store could not be read (e.g. Keychain locked before first unlock).
    case unavailable
}

/// Persistence for the phone's stable device-registry id.
///
/// The id must survive an app reinstall so the iroh binding slot keyed on
/// `(user, device, tag)` is reused instead of orphaned. iOS `UserDefaults` is
/// erased on delete/reinstall, but a device-only Keychain item is not, so the
/// Keychain is authoritative and `UserDefaults` is only a legacy migration
/// source and downgrade mirror.
protocol DeviceIdentityStoring: Sendable {
    func read() -> DeviceIdentityReadResult
    /// Persist `deviceID`, returning whether it is now durably stored.
    ///
    /// The caller must not advertise a freshly minted id as durable until this
    /// reports `true`: if the write failed, only the reinstall-volatile
    /// `UserDefaults` mirror would hold it, so a delete/reinstall would mint a
    /// different id and strand the binding this store exists to preserve.
    @discardableResult
    func write(_ deviceID: String) -> Bool
}

/// Device-only Keychain storage for the device-registry id.
///
/// Uses a service name distinct from the iroh endpoint-identity store, so the
/// reinstall/sign-out wipe in `CmxIrohIdentityRepository` (which deletes only
/// the endpoint-identity service) never removes this id. `write` reports whether
/// persistence actually succeeded so the caller never treats an unpersisted id
/// as durable, and a read distinguishes "no item" (`.absent`) from "cannot read
/// the item" (`.unavailable`) so the caller never mints a fresh id while the
/// real one is merely temporarily unreadable.
struct KeychainDeviceIdentityStore: DeviceIdentityStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.cmuxterm.deviceRegistry.iosDeviceID.v1",
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    func read() -> DeviceIdentityReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            // A present item that does not decode to a non-empty UTF-8 string is
            // corrupt, not locked: report `.absent` so the caller re-mints and
            // overwrites it rather than failing closed against a garbage value.
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else {
                return .absent
            }
            return .found(value)
        case errSecItemNotFound:
            return .absent
        default:
            // `errSecInteractionNotAllowed` (item exists but the Keychain is
            // locked before first unlock) and any other error: we cannot prove
            // the id is absent, so do not let the caller mint a replacement.
            return .unavailable
        }
    }

    @discardableResult
    func write(_ deviceID: String) -> Bool {
        guard let data = deviceID.data(using: .utf8) else { return false }
        let query = baseQuery()
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        // Lost an add race with a concurrent writer (the item now exists): an
        // update proves it is persisted. `errSecDuplicateItem` is the only
        // status where retrying is correct; every other error is a real failure.
        guard addStatus == errSecDuplicateItem else { return false }
        let retryStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        return retryStatus == errSecSuccess
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// In-memory device-identity store for tests. Not for production use.
final class InMemoryDeviceIdentityStore: DeviceIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    /// Simulates a store that cannot be read (e.g. a locked Keychain): `read()`
    /// returns `.unavailable` regardless of the seed, exercising the caller's
    /// fail-closed path.
    private let isUnavailable: Bool
    /// Simulates a store that can be read but never persists a write (e.g. a
    /// Keychain that rejects `SecItemAdd`), exercising the caller's
    /// do-not-advertise-as-durable path.
    private let writeAlwaysFails: Bool

    init(seed: String? = nil, unavailable: Bool = false, writeAlwaysFails: Bool = false) {
        value = seed
        isUnavailable = unavailable
        self.writeAlwaysFails = writeAlwaysFails
    }

    func read() -> DeviceIdentityReadResult {
        if isUnavailable { return .unavailable }
        return lock.withLock {
            guard let value, !value.isEmpty else { return .absent }
            return .found(value)
        }
    }

    @discardableResult
    func write(_ deviceID: String) -> Bool {
        if writeAlwaysFails { return false }
        lock.withLock { value = deviceID }
        return true
    }
}
