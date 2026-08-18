import Foundation
import Security

/// Evidence that this install is CONTINUING on the same physical device, used
/// to decide whether a legacy `UserDefaults` device-id mirror may be adopted
/// when the authoritative device-id Keychain item is absent.
///
/// The dilemma it resolves: on an in-place UPGRADE from a pre-Keychain build,
/// the device-id Keychain item does not exist yet while `UserDefaults` holds
/// the id of the phone's active device-registry record. Minting a fresh id there
/// targets a new `(user, device, tag)` slot while the old record still owns the
/// previous slot, so registration can fail and the upgrading install loses its
/// device continuity. But `UserDefaults` alone cannot be
/// adopted blindly, because an encrypted device backup restores it onto
/// DIFFERENT hardware, where adoption would make two phones share one slot.
///
/// The discriminator is a device-only Keychain marker, stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and
/// `kSecAttrSynchronizable = false`, so it can NEVER cross hardware via backup
/// or iCloud sync. Upgrade/restore matrix:
///
/// - Upgrade in place: mirror present, continuity marker present → ADOPT.
/// - Restore to new hardware: mirror present (backups carry UserDefaults),
///   continuity marker absent (ThisDeviceOnly) → MINT.
/// - Same-device erase + restore: continuity marker absent → MINT (safe: the
///   old marker was lost too, so the record is re-keyed on next registration).
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

/// Probes for a device-only continuity marker. The old endpoint-identity
/// service is read once as migration evidence so an upgraded install keeps its
/// registry identity, but the new transport never writes or depends on it.
public struct DeviceContinuityEvidenceProbe: SameDeviceEvidenceProbing {
    private let services: [String]

    public init(
        service: String = "com.cmuxterm.transport.device-continuity.v1",
        legacyServices: [String] = [
            "com.cmuxterm.iroh.endpoint-identity.v1",
        ]
    ) {
        self.services = Array(
            Set([service] + legacyServices)
        ).sorted()
    }

    public init(services: [String]) {
        self.services = Array(Set(services)).sorted()
    }

    public func probe() -> SameDeviceEvidence {
        var sawUnavailable = false
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            switch SecItemCopyMatching(query as CFDictionary, nil) {
            case errSecSuccess:
                return .present
            case errSecItemNotFound:
                continue
            default:
                sawUnavailable = true
            }
        }
        return sawUnavailable ? .unavailable : .absent
    }
}

/// Source compatibility for callers from the pre-stable transport release.
@available(*, deprecated, renamed: "DeviceContinuityEvidenceProbe")
public typealias IrohEndpointIdentityEvidenceProbe = DeviceContinuityEvidenceProbe
