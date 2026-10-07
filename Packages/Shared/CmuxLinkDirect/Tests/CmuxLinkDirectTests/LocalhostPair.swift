import CmuxLink
@_spi(Testing) import CmuxLinkDirect
import Foundation

/// A real listener on 127.0.0.1 and a dialer pinned to it.
struct LocalhostPair {
    let hostID = "conformance-host"
    let host = DirectIdentity()
    let device = DirectIdentity()
    let injector = DirectFaultInjector()
    let acceptor: DirectAcceptor
    let port: UInt16

    init(authorized: Set<DirectPublicKey>? = nil) async throws {
        let device = device
        acceptor = DirectAcceptor(
            identity: host,
            hostID: hostID,
            configuration: DirectListenConfiguration(port: 0, localAddress: "127.0.0.1"),
            authorizer: DirectPinnedAuthorizer(allowed: authorized ?? [device.publicKey]),
            faultInjector: injector
        )
        port = try await acceptor.start()
    }

    func endpoint(hostKey: DirectPublicKey? = nil) -> DirectEndpoint {
        DirectEndpoint(address: DirectAddress("127.0.0.1")!, port: port, hostKey: hostKey ?? host.publicKey)
    }

    func peer(hostID: String? = nil, hostKey: DirectPublicKey? = nil) -> LinkPeer {
        LinkPeer(hostID: hostID ?? self.hostID, hints: DirectHintsResolver().hints(for: endpoint(hostKey: hostKey)))
    }

    func carrier(identity: DirectIdentity? = nil) -> DirectCarrier {
        DirectCarrier(identity: identity ?? device, resolver: DirectHintsResolver(), routes: nil, faultInjector: injector)
    }
}
