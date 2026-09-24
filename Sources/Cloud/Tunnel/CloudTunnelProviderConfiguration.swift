import Foundation

struct CloudTunnelProviderConfiguration: Sendable, Equatable {
    /// Completed wg-quick config (private key filled in).
    let wgQuickConfig: String
    /// `host:port` of the WireGuard peer, shown by System Settings as the
    /// VPN's server address.
    let serverAddress: String
    /// The VPN configuration's name in System Settings.
    let localizedDescription: String
}
