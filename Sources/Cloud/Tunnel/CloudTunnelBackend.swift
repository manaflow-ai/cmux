import Foundation

/// How this build brings the WireGuard tunnel into the Cloud VM network up.
///
/// Decided once per launch by ``CloudTunnelBackendSelector`` from what the
/// running binary can actually do, so the same source degrades to the CLI
/// path on builds that lack the signed capability or the bundled extension.
enum CloudTunnelBackend: Sendable, Equatable {
    /// The app owns the tunnel through its bundled network system extension:
    /// no sudo, no wg-quick, started on demand when the user opens a machine.
    case networkExtension(extensionBundleIdentifier: String)
    /// `cmux vpn up` runs `sudo wg-quick` on the app-written config. The
    /// shipping path until release signing carries the tunnel capability.
    case wgQuick(CloudTunnelFallbackReason)

    var isNetworkExtension: Bool {
        if case .networkExtension = self { return true }
        return false
    }

    var extensionBundleIdentifier: String? {
        if case .networkExtension(let identifier) = self { return identifier }
        return nil
    }

    var fallbackReason: CloudTunnelFallbackReason? {
        if case .wgQuick(let reason) = self { return reason }
        return nil
    }

    /// Stable token for socket payloads and `cmux vpn status`.
    var wireName: String {
        switch self {
        case .networkExtension: return "network-extension"
        case .wgQuick: return "wg-quick"
        }
    }
}

/// Why a build falls back to wg-quick. Each case names the exact missing
/// piece so `cmux vpn status` can say what is absent instead of "unavailable".
