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

    /// The production presence worker (prod Stack project), the Release-build
    /// default so stable cmux can announce presence once the user enables mobile.
    /// See workers/presence/README.md.
    static let productionServiceURL = "https://presence.cmux.dev"

    /// Whether the heartbeat gate is on. An explicitly written value always wins.
    /// With no stored value, presence FOLLOWS the hosting opt-ins: announcing the
    /// Mac only makes sense once something may connect to it, either the iPhone
    /// (iOS pairing, ``MobileHostService/isListeningEnabled``) or the account's
    /// other Macs (incoming Mac access). Either opt-in alone must announce, or
    /// peers list this Mac from discovery but always label it offline.
    /// Default (both off) => off, for privacy: the Mac announces nothing until
    /// the user opts into being reachable.
    static func isEnabled(defaults: UserDefaults = .standard, cloudEnabled: Bool? = nil) -> Bool {
        guard MobileHostService.isListeningEnabled(defaults: defaults)
            || MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults, cloudEnabled: cloudEnabled)
        else { return false }
        if defaults.object(forKey: enabledKey) != nil {
            return defaults.bool(forKey: enabledKey)
        }
        return true
    }
}
