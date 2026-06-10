import Foundation

/// UserDefaults keys for the device presence heartbeat. Default OFF: the Mac
/// announces nothing unless the flag is enabled and a service URL is set.
enum PresenceSettings {
    /// Master gate. When false (default), no heartbeats are sent.
    static let enabledKey = "presenceHeartbeatEnabled"
    /// Base URL of the presence service (the cmux-presence worker), e.g.
    /// "https://cmux-presence.<account>.workers.dev". Empty means disabled.
    static let serviceURLKey = "presenceServiceURL"
    /// Env override for dev/tagged builds, mirroring CMUX_VM_API_BASE_URL.
    static let serviceURLEnvKey = "CMUX_PRESENCE_BASE_URL"
}
