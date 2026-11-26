import Foundation
#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif

/// Tailscale-only mode (Settings → Transport → Tailscale Only, PROTOCOL.md "Tailscale-only
/// links"): the phone reaches its Macs over the person's tailnet through the Tailscale app's own
/// VPN, and the built-in WireGuard never runs. cmux adds no VPN configuration of its own in any
/// mode; this mode only stops cmux's own tunnel.
public enum TailscaleOnly {
    /// Settings → Transport → Fall Back to WireGuard (`CmuxMobileModel.SettingsStore.tailscaleFallback`,
    /// the same key; this module does not link the model). Off by default: someone who chose
    /// Tailscale only gets a clear error, never a tunnel they did not choose.
    public static let fallbackKey = "cmuxMobile.settings.tailscaleFallback"

    /// Whether a Tailscale-only dial that cannot use Tailscale dials the built-in WireGuard instead.
    public static func fallsBack(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: fallbackKey)
    }

    /// Whether this iPhone has a tailnet address now: the Tailscale app's VPN is connected.
    public static func isConnected() -> Bool {
        #if canImport(CmuxMobileLinkFFI)
        return tailscaleConnected()
        #else
        return false
        #endif
    }
}
