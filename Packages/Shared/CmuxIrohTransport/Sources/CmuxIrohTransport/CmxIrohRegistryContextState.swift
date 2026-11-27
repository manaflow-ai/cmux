import Foundation

struct CmxIrohRegistryGrantCache: Sendable {
    let initiator: CmxIrohGrantPeer
    let acceptor: CmxIrohGrantPeer
    let response: CmxIrohPairGrantResponse
    let expiresAt: Date
}

struct CmxIrohRegistryLANAuthority: Sendable {
    let target: CmxIrohBrokerBinding
    let bindings: [CmxIrohBrokerBinding]
    let rendezvous: CmxIrohLANRendezvous
}
