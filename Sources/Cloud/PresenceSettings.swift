import Foundation

/// UserDefaults keys for the device presence heartbeat.
///
/// Release default OFF: a stable Mac announces nothing unless the flag is
/// enabled and a service URL is set (the production worker URL ships with the
/// Settings surface as a follow-up). Debug default ON against the dev/staging
/// instance: Debug builds sign into the dev Stack project, which is exactly
/// what `cmux-presence-dev` verifies, so tagged dogfood builds get live
/// presence with zero setup while both defaults stay explicitly overridable.
enum PresenceSettings {
    /// Master gate. Resolved by ``isEnabled(defaults:)``; an explicit value
    /// always wins, otherwise Debug defaults on and Release off.
    static let enabledKey = "presenceHeartbeatEnabled"
    /// Base URL of the presence service (the cmux-presence worker), e.g.
    /// "https://cmux-presence.<account>.workers.dev". Empty means disabled.
    static let serviceURLKey = "presenceServiceURL"
    /// Env override for dev/tagged builds, mirroring CMUX_VM_API_BASE_URL.
    static let serviceURLEnvKey = "CMUX_PRESENCE_BASE_URL"
    /// The dev/staging worker (dev Stack project), the Debug-build default.
    /// See workers/presence/README.md.
    static let debugDefaultServiceURL = "https://cmux-presence-dev.debussy.workers.dev"

    /// Whether the heartbeat gate is on. An explicitly written value always
    /// wins; with no stored value, Debug builds default to enabled (dev Stack
    /// identity + dev service URL make this safe and dogfood-ready) and
    /// Release builds to disabled.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) != nil {
            return defaults.bool(forKey: enabledKey)
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
