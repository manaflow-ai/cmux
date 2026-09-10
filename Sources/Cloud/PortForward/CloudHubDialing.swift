import Foundation

/// Hands out claims on the hub's SOCKS5 socket, starting the hub when it is
/// not running. ``CloudWireGuardHubDialer`` is the production implementation
/// over ``CloudWireGuardHub``; tests point it at a fake SOCKS5 server.
protocol CloudHubDialing: Sendable {
    func claimHubSocket() async throws -> CloudHubSocketClaim
}
