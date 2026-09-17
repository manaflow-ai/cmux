import Foundation
import Network

/// A claim on the user-space WireGuard hub's SOCKS5 socket for one tunneled
/// connection. `release` gives the hub's lease back once the connection ends;
/// the hub idle-stops a little after its last lease goes.
struct CloudHubSocketClaim: Sendable {
    let endpoint: NWEndpoint
    let release: @Sendable () async -> Void
}
