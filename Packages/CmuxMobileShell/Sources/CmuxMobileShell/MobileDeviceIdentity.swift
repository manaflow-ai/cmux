public import Foundation

/// This iOS device's stable cmux identity for the device registry.
///
/// A cmux-GENERATED persisted UUID (NOT `identifierForVendor`, which resets when
/// the last cmux app is removed, and NOT a hardware fingerprint). Persisted in
/// `UserDefaults` so it survives relaunch and reinstall-while-other-cmux-apps-
/// present, is cross-platform, and is user-renamable via its display name.
///
/// Mirrors the Mac side's `MobileHostIdentity.deviceID()` so both ends of the
/// registry use the same identity shape. The phone sends this id when it
/// registers itself as a device; the registry's key-pinning phase will later
/// anchor a pinned key to it for revoke.
public enum MobileDeviceIdentity {
    private static let deviceIDKey = "cmux.deviceRegistry.iosDeviceID"

    /// The persisted device UUID, generating and storing one on first use.
    /// - Parameter defaults: Persistence store (injected for tests).
    public static func deviceID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: deviceIDKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: deviceIDKey)
        return generated
    }
}
