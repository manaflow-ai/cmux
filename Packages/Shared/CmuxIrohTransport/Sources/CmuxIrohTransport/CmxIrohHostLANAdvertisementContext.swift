/// Verified account-private material needed for local-link advertisement.
public struct CmxIrohHostLANAdvertisementContext: Equatable, Sendable {
    public let binding: CmxIrohBrokerBindingMetadata
    public let rendezvous: CmxIrohLANRendezvous

    public init(
        binding: CmxIrohBrokerBindingMetadata,
        rendezvous: CmxIrohLANRendezvous
    ) {
        self.binding = binding
        self.rendezvous = rendezvous
    }
}
