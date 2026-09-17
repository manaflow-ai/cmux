import Foundation

/// How this build brings the WireGuard tunnel into the Cloud VM network up.
///
/// Decided once per launch by ``CloudTunnelBackendSelector`` from what the
/// running binary can actually do. A build without the signed capability
/// fails closed. It never asks for sudo or starts wg-quick.
enum CloudTunnelBackend: Sendable, Equatable {
    /// The app owns the tunnel through its bundled network system extension:
    /// no sudo, no wg-quick, started on demand when the user opens a machine.
    case networkExtension(extensionBundleIdentifier: String)
    case unavailable(CloudTunnelFallbackReason)

    var isNetworkExtension: Bool {
        if case .networkExtension = self { return true }
        return false
    }

    var extensionBundleIdentifier: String? {
        if case .networkExtension(let identifier) = self { return identifier }
        return nil
    }

    var unavailableReason: CloudTunnelFallbackReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// Stable token for socket payloads and `cmux vpn status`.
    var wireName: String {
        switch self {
        case .networkExtension: return "network-extension"
        case .unavailable: return "unavailable"
        }
    }
}

/// Why this build cannot start the browser Network Extension tunnel.
