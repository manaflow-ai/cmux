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

/// Device-only Keychain storage for the device-registry id.
///
/// Uses a service name distinct from the iroh endpoint-identity store, so the
/// reinstall/sign-out wipe in `CmxIrohIdentityRepository` (which deletes only
/// the endpoint-identity service) never removes this id. `createOrAdopt` reports
/// the id the store actually holds so the caller never treats an unpersisted id
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

    func createOrAdopt(_ desired: String) -> String? {
        guard let data = desired.data(using: .utf8) else { return nil }
        var insert = baseQuery()
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
            switch read() {
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
                // the device could never mint an id and iroh activation would be
                // permanently disabled. Overwrite the corrupt item with `desired`.
                // (A concurrent delete between add and read also lands here;
                // `SecItemUpdate` then fails with `errSecItemNotFound` and we
                // return `nil` so the caller retries a clean add.)
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
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
