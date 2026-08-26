import Foundation
import Security

/// Evidence that this install is CONTINUING on the same physical device, used
/// to decide whether a legacy `UserDefaults` device-id mirror may be adopted
/// when the authoritative device-id Keychain item is absent.
///
/// The dilemma it resolves: on an in-place UPGRADE from a pre-Keychain build,
/// the device-id Keychain item does not exist yet while `UserDefaults` holds
/// the durable device id the account services already know — minting a fresh
/// id there breaks continuity with server-side per-device state. But
/// `UserDefaults` alone cannot be adopted blindly, because an encrypted device
/// backup restores it onto DIFFERENT hardware, where adoption would make two
/// phones share one identity.
///
/// The discriminator is a ThisDeviceOnly Keychain item written by the prior
/// install: stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and
/// `kSecAttrSynchronizable = false`, so it can NEVER cross hardware via backup
/// or iCloud sync. Upgrade/restore matrix:
///
/// - Upgrade in place: mirror present, device-local item present → ADOPT.
/// - Restore to new hardware: mirror present (backups carry UserDefaults),
///   device-local item absent (ThisDeviceOnly) → MINT.
/// - Same-device erase + restore: device-local item absent → MINT (safe: the
///   prior device-local state was lost too).
/// - Fresh install: mirror absent → MINT (evidence never consulted).
/// - Keychain locked (`errSecInteractionNotAllowed`): cannot prove either way
///   → NO evidence, mint is deferred by the caller's existing `.unavailable`
///   path when the device-id store is also unreadable; when only this probe is
///   locked, fail toward MINT-safe `false` is wrong (it would rotate an
///   upgrading device), so the probe reports `.unavailable` and resolution
///   defers, mirroring the device-id store's own fail-closed behavior.
public protocol SameDeviceEvidenceProbing: Sendable {
    func probe() -> SameDeviceEvidence
}

public enum SameDeviceEvidence: Equatable, Sendable {
    /// A ThisDeviceOnly artifact from the prior install exists on this device.
    case present
    /// No such artifact exists (fresh install, or restore onto new hardware).
    case absent
    /// The Keychain cannot be read right now (locked before first unlock).
    case unavailable
}

/// Probes for any item under a device-local (ThisDeviceOnly, non-synchronizable)
/// Keychain identity service written by prior installs.
///
/// The default service name is a persisted-data compatibility constant: it
/// preserves device-identity continuity from the retired transport's
/// endpoint-identity store, whose items are the durable same-device artifact
/// upgrading installs already carry. The probe only asks "does any item
/// exist" — it never reads key material (`kSecReturnData` is not set).
public struct KeychainIdentityEvidenceProbe: SameDeviceEvidenceProbing {
    private let service: String

    public init(service: String = "com.cmuxterm.iroh.endpoint-identity.v1") {
        self.service = service
    }

    public func probe() -> SameDeviceEvidence {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .present
        case errSecItemNotFound:
            return .absent
        default:
            return .unavailable
        }
    }
}
