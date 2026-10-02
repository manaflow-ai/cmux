import Foundation
import Network

/// A claim on the user-space WireGuard hub's SOCKS5 socket for one tunneled
/// connection. `release` gives the hub's lease back once the connection ends;
/// the hub idle-stops a little after its last lease goes.
public struct CloudHubSocketClaim: Sendable {
    public init(
        endpoint: NWEndpoint,
        release: @escaping @Sendable () async -> Void
    ) {
        self.endpoint = endpoint
        self.release = release
    }

    public let endpoint: NWEndpoint
    public let release: @Sendable () async -> Void
}
