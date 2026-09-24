import Foundation

struct CloudTunnelEnrollment: Sendable, Equatable {
    /// Completed wg-quick config (private key filled in). Never logged.
    let wgQuickConfig: String
    /// `host:port` of the WireGuard peer.
    let serverAddress: String
}
