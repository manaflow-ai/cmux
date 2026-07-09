import CmuxSettings
import Foundation

/// The Mac-side iOS-pairing listener's settings, read from a `UserDefaults`
/// receiver.
///
/// A value type over the `UserDefaults` it reads, so each settings query is a
/// plain property access on a constructed value instead of a static accessor on
/// the host service. The defaults *keys* themselves remain owned by
/// ``MobileHostService`` (`listeningEnabledDefaultsKey` / `portDefaultsKey`),
/// since the pairing model, the running-listener reconcile path, and the
/// invalid-port `resolvedDesiredPort` guard all read the same keys.
struct MobileHostListenerSettings {
    /// The defaults store these settings are read from.
    let defaults: UserDefaults

    /// Reads listener settings from `defaults` (defaults to `.standard`).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the mobile pairing host should bind a network listener at all.
    ///
    /// Defaults off in every build so macOS does not ask for Local Network
    /// permission until the user enables iOS pairing in Settings.
    var isListeningEnabled: Bool {
        if let override = defaults.object(forKey: MobileHostService.listeningEnabledDefaultsKey) as? Bool {
            return override
        }
        return SettingCatalog().mobile.iOSPairingHost.defaultValue
    }

    /// The preferred TCP port the listener should try to bind, read from
    /// settings.
    ///
    /// Falls back to the catalog default (which mirrors
    /// `CmxMobileDefaults.defaultHostPort`) when unset or outside the valid
    /// `1...65535` range. The listener still falls back to an OS-assigned
    /// ephemeral port if this port is unavailable at bind time.
    var configuredPort: Int {
        let fallback = SettingCatalog().mobile.iOSPairingPort.defaultValue
        guard let raw = defaults.object(forKey: MobileHostService.portDefaultsKey) as? Int else {
            return fallback
        }
        return (1...65535).contains(raw) ? raw : fallback
    }
}
