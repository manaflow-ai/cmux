import Foundation

public struct CloudTunnelProviderConfiguration: Sendable, Equatable {
    public init(
        wgQuickConfig: String,
        serverAddress: String,
        localizedDescription: String
    ) {
        self.wgQuickConfig = wgQuickConfig
        self.serverAddress = serverAddress
        self.localizedDescription = localizedDescription
    }

    /// Completed wg-quick config (private key filled in).
    public let wgQuickConfig: String
    /// `host:port` of the WireGuard peer, shown by System Settings as the
    /// VPN's server address.
    public let serverAddress: String
    /// The VPN configuration's name in System Settings.
    public let localizedDescription: String
}
