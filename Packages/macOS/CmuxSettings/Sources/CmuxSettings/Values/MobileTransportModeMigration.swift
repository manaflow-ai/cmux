import Foundation

/// One-time migration from the legacy mobile-host booleans
/// (`mobile.iOSPairingHost.enabled` / `mobile.iOSIrohHost.enabled`) to the
/// single ``MobileTransportMode`` enum (`mobile.iOSTransportMode`).
///
/// This is not a 1:1 key rename (two booleans collapse into one enum), so it
/// can't use `DefaultsKey.legacyUserDefaultsKeys`. Run once at startup before
/// the mobile host reads its mode.
public enum MobileTransportModeMigration {
    static let modeKey = "mobile.iOSTransportMode"
    static let legacyIrohKey = "mobile.iOSIrohHost.enabled"
    static let legacyPairingKey = "mobile.iOSPairingHost.enabled"

    /// Derives a mode from the legacy boolean pair and persists it, unless the
    /// new key is already set or this is a fresh install (no legacy keys). Old
    /// keys are removed after a successful derivation so defaults stay clean.
    ///
    /// Idempotent: a no-op once `mobile.iOSTransportMode` exists.
    public static func runIfNeeded(defaults: UserDefaults = .standard) {
        // Already chosen (by a prior migration or by the user): leave it.
        guard defaults.object(forKey: modeKey) == nil else { return }

        let hadIroh = defaults.object(forKey: legacyIrohKey) as? Bool
        let hadPairing = defaults.object(forKey: legacyPairingKey) as? Bool

        // Fresh install: no legacy state. Leave the key unset so the catalog
        // default (cmuxRelay) applies and onboarding makes the choice explicit.
        guard hadIroh != nil || hadPairing != nil else { return }

        let derived = derivedMode(hadIroh: hadIroh, hadPairing: hadPairing)
        defaults.set(derived.rawValue, forKey: modeKey)
        defaults.removeObject(forKey: legacyIrohKey)
        defaults.removeObject(forKey: legacyPairingKey)
    }

    /// Pure mapping, exposed for tests:
    /// - iroh host on → cmuxRelay (it was already on the iroh lane).
    /// - iroh off but pairing on → tailscale (TCP/tailnet was the active lane).
    /// - otherwise → cmuxRelay (the always-on default; onboarding confirms it).
    static func derivedMode(hadIroh: Bool?, hadPairing: Bool?) -> MobileTransportMode {
        if hadIroh == true {
            return .cmuxRelay
        }
        if hadPairing == true {
            return .tailscale
        }
        return .cmuxRelay
    }
}
