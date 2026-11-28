import Foundation

public struct CloudTunnelEnrollment: Sendable, Equatable {
    public init(
        wgQuickConfig: String,
        serverAddress: String
    ) {
        self.wgQuickConfig = wgQuickConfig
        self.serverAddress = serverAddress
    }

    /// Completed wg-quick config (private key filled in). Never logged.
    public let wgQuickConfig: String
    /// `host:port` of the WireGuard peer.
    public let serverAddress: String
}
