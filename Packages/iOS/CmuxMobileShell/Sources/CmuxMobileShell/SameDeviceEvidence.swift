import Foundation
import Security

/// Evidence that this install is CONTINUING on the same physical device, used
/// to decide whether a legacy `UserDefaults` device-id mirror may be adopted
/// when the authoritative device-id Keychain item is absent.
///
/// The dilemma it resolves: on an in-place UPGRADE from a pre-Keychain build,
/// the device-id Keychain item does not exist yet while `UserDefaults` holds
/// the id of the phone's ACTIVE iroh binding — minting a fresh id there targets
/// a new `(user, device, tag)` slot while the surviving endpoint identity still
/// owns the old slot, so registration fails `endpoint_already_bound` and iroh
/// is disabled for every upgrading install. But `UserDefaults` alone cannot be
/// adopted blindly, because an encrypted device backup restores it onto
/// DIFFERENT hardware, where adoption would make two phones share one slot.
///
/// The discriminator is the iroh endpoint-identity Keychain item: it is stored
/// with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and
/// `kSecAttrSynchronizable = false` (`CmxIrohKeychainIdentityStore` in
/// CmuxIrohTransport), so it can NEVER cross hardware via backup or iCloud
/// sync. Upgrade/restore matrix:
///
/// - Upgrade in place: mirror present, endpoint identity present → ADOPT.
/// - Restore to new hardware: mirror present (backups carry UserDefaults),
///   endpoint identity absent (ThisDeviceOnly) → MINT.
/// - Same-device erase + restore: endpoint identity absent → MINT (safe: the
///   endpoint key was lost too, so the old binding is re-keyed on next
///   registration either way).
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

/// Probes for any item under the iroh endpoint-identity Keychain service.
///
/// CROSS-PACKAGE CONTRACT: the service name mirrors
/// `CmxIrohKeychainIdentityStore.init(service:)` in CmuxIrohTransport
/// ("com.cmuxterm.iroh.endpoint-identity.v1"). CmuxMobileShell does not depend
/// on CmuxIrohTransport, so the constant is duplicated here deliberately; both
/// sites carry a comment pointing at the other. The probe only asks "does any
/// item exist" — it never reads key material (`kSecReturnData` is not set).
public struct IrohEndpointIdentityEvidenceProbe: SameDeviceEvidenceProbing {
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
