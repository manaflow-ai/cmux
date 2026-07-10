/// The stable cryptographic identity of an Iroh endpoint.
///
/// This value identifies the peer independently from every address or relay
/// hint used to reach it. A route may change hints without changing identity.
public struct CmxIrohPeerIdentity: Codable, Equatable, Hashable, Sendable {
    /// The Iroh endpoint identifier presented by the route.
    public let endpointID: String

    /// Creates an Iroh peer identity from an endpoint identifier.
    ///
    /// Structural route validation rejects an empty identifier.
    /// - Parameter endpointID: The stable Iroh endpoint identifier.
    public init(endpointID: String) {
        self.endpointID = endpointID
    }
}
