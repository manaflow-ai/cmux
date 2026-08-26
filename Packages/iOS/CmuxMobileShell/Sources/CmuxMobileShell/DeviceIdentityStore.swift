import Foundation
internal import os
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
/// The id must survive an app reinstall so account services keep addressing
/// the same `(user, device, tag)` identity instead of orphaning it. iOS
/// `UserDefaults` is erased on delete/reinstall, but a device-only Keychain
/// item is not, so the Keychain is authoritative and `UserDefaults` is only a
/// legacy migration source and downgrade mirror.
protocol DeviceIdentityStoring: Sendable {
    /// Classify the persisted id. A stored value that is blank after trimming
    /// whitespace is CORRUPT and must classify as `.absent` (so the caller
    /// re-mints and `createOrAdopt` overwrites it), never `.found`: callers
    /// trim every id before use, so a whitespace-only `.found` deadlocks the
    /// repair by being endlessly re-adopted.
    func read() -> DeviceIdentityReadResult
    /// Persist `desired` only if the store currently holds no id, otherwise adopt
    /// the id already present. Returns the id the store holds afterward (the given
    /// id when this call created it, or the pre-existing winner), or `nil` when no
    /// id could be persisted or read back.
    ///
    /// This is the safe primitive for minting: it never overwrites a value a
    /// concurrent resolution already won, so two launches that each mint a
    /// different candidate converge on ONE id. A last-writer-wins `update` would
    /// instead let the loser clobber the winner, leaving the winner's caller
    /// advertising an id the store no longer holds and stranding that binding on
    /// the next launch. The caller must not advertise a freshly minted id as
    /// durable until this returns non-`nil`: on `nil` only the reinstall-volatile
    /// `UserDefaults` mirror would hold it, so a delete/reinstall would mint a
    /// different id and strand the binding this store exists to preserve.
    func createOrAdopt(_ desired: String) -> String?
}

/// Authoritative device-id storage for an iOS Simulator process.
///
/// Unsigned simulator apps do not have an application identifier entitlement,
/// so data-protection Keychain operations fail even after the simulated device
/// is unlocked. Simulator identity therefore lives in the app's defaults
/// domain. A launcher-provided deterministic seed survives app-container
/// recreation by being adopted on the next launch, while an ordinary
/// SpringBoard relaunch reads the value persisted by the first launch.
/// The simulator deliberately uses the legacy mirror key as its authoritative
/// key because simulator app containers do not provide the physical device's
/// reinstall-stable Keychain boundary. This behavior is simulator-only.
///
/// This type is compiled for tests on macOS, but production selection is
/// guarded by `targetEnvironment(simulator)`. Physical devices continue to use
/// ``KeychainDeviceIdentityStore`` and its fail-closed semantics.
final class SimulatorDeviceIdentityStore: DeviceIdentityStoring, @unchecked Sendable {
    // This synchronous compare-and-set spans callers that cannot share an
    // actor boundary. DeviceIdentityStoring has synchronous requirements, so
    // actor isolation is not a drop-in replacement. The lock protects only one
    // UserDefaults read/write pair.
    private static let processLock = OSAllocatedUnfairLock(initialState: ())
    private static let deviceIDKey = "cmux.deviceRegistry.iosDeviceID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults, seededDeviceID: String? = nil) {
        self.defaults = defaults
        if let seededDeviceID = Self.usable(seededDeviceID) {
            _ = createOrAdopt(seededDeviceID)
        }
    }

    func read() -> DeviceIdentityReadResult {
        Self.processLock.withLock { _ in
            readLocked()
        }
    }

    func createOrAdopt(_ desired: String) -> String? {
        Self.processLock.withLock { _ in
            switch readLocked() {
            case .found(let winner):
                return winner
            case .absent:
                guard let candidate = Self.usable(desired) else { return nil }
                defaults.set(candidate, forKey: Self.deviceIDKey)
                return Self.usable(defaults.string(forKey: Self.deviceIDKey))
            case .unavailable:
                // UserDefaults has no temporarily-locked state.
                return nil
            }
        }
    }

    private func readLocked() -> DeviceIdentityReadResult {
        if let persisted = Self.usable(defaults.string(forKey: Self.deviceIDKey)) {
            return .found(persisted)
        }
        return .absent
    }

    private static func usable(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Device-only Keychain storage for the device-registry id.
///
/// Uses a service name distinct from the retired transport's endpoint-identity
/// store, so historical sign-out wipes of that other service never removed
/// this id. `createOrAdopt` reports
/// the id the store actually holds so the caller never treats an unpersisted id
/// as durable, and a read distinguishes "no item" (`.absent`) from "cannot read
/// the item" (`.unavailable`) so the caller never mints a fresh id while the
/// real one is merely temporarily unreadable.
struct KeychainDeviceIdentityStore: DeviceIdentityStoring {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let legacyService: String?

    init(
        service: String = "com.cmuxterm.deviceRegistry.iosDeviceID.v1",
        account: String = "default",
        accessGroup: String? = nil,
        legacyService: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.legacyService = legacyService == service ? nil : legacyService
    }

    func read() -> DeviceIdentityReadResult {
        let current = read(service: service)
        guard current == .absent, let legacyService else {
            return current
        }
        switch read(service: legacyService) {
        case .found(let legacy):
            guard let winner = createOrAdopt(legacy) else {
                return .unavailable
            }
            _ = SecItemDelete(
                baseQuery(service: legacyService) as CFDictionary
            )
            return .found(winner)
        case .absent:
            return .absent
        case .unavailable:
            return .unavailable
        }
    }

    private func read(service: String) -> DeviceIdentityReadResult {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            // A present item that does not decode to a usable UTF-8 string is
            // corrupt, not locked: report `.absent` so the caller re-mints and
            // overwrites it rather than failing closed against a garbage value.
            // "Usable" means non-blank AFTER trimming — the resolver trims every
            // id before use, so classifying a whitespace-only value as `.found`
            // would deadlock the repair: the caller notices the blank and mints,
            // but `createOrAdopt`'s duplicate-item path re-reads this same value
            // and adopts it, so the corrupt item is never overwritten.
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    func createOrAdopt(_ desired: String) -> String? {
        guard let data = desired.data(using: .utf8) else { return nil }
        var insert = baseQuery(service: service)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            // This call created the item; `desired` is now the persisted id.
            return desired
        case errSecDuplicateItem:
            // An item already exists. Resolve what it holds so racing callers
            // converge on one id and a corrupt item cannot wedge minting forever.
            switch read(service: service) {
            case .found(let existing):
                // A concurrent writer already persisted a usable id. Adopt it so
                // every racing caller converges on one id, never overwriting the
                // winner.
                return existing
            case .absent:
                // `read()` maps a PRESENT-but-undecodable item to `.absent` (its
                // documented contract: "report `.absent` so the caller re-mints
                // and overwrites it"). Without overwriting, this deadlocks: the
                // next `SecItemAdd` keeps returning `errSecDuplicateItem` while the
                // garbage item squats and `read()` keeps returning `.absent`, so
                // the device could never mint an id and per-device registry
                // state would wedge. Overwrite the corrupt item with `desired`.
                // (A concurrent delete between add and read also lands here;
                // `SecItemUpdate` then fails with `errSecItemNotFound` and we
                // return `nil` so the caller retries a clean add.)
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                let updateStatus = SecItemUpdate(
                    baseQuery(service: service) as CFDictionary,
                    attributes as CFDictionary
                )
                return updateStatus == errSecSuccess ? desired : nil
            case .unavailable:
                // The item exists but the Keychain is locked before first unlock.
                // Do not clobber a possibly-valid id under a garbage value; report
                // failure so the caller defers and retries after unlock instead of
                // stranding a binding under an id the Keychain never kept.
                return nil
            }
        default:
            // Locked before first unlock (`errSecInteractionNotAllowed`) or any
            // other error: nothing was persisted, so the caller must not treat
            // `desired` as durable.
            return nil
        }
    }

    private func baseQuery(service: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
