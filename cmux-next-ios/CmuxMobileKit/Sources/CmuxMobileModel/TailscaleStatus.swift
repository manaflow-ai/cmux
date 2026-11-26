import Foundation

/// Whether this iPhone is on a tailnet now (the Tailscale app's VPN is connected), for
/// Settings → Transport's Tailscale row. The shell sets ``probe`` to the link core's check
/// (`TailscaleOnly.isConnected`) at launch; this module does not link the transport.
public enum TailscaleStatus {
    /// The check; `false` until the shell sets it (previews, tests).
    nonisolated(unsafe) public static var probe: @Sendable () -> Bool = { false }

    /// A debug and screenshot override, `CMUX_MOBILE_DEV_TAILSCALE=on|off`: the Settings row
    /// shows that state whatever the device's interfaces say. Compiled out of Release.
    public static var isConnected: Bool {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["CMUX_MOBILE_DEV_TAILSCALE"] {
        case "on": return true
        case "off": return false
        default: break
        }
        #endif
        return probe()
    }

    /// The Tailscale app's URL scheme, to open it from Settings.
    public static let appURL = URL(string: "tailscale://")!
    /// Tailscale on the App Store, when the app is not installed.
    public static let appStoreURL = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
}
