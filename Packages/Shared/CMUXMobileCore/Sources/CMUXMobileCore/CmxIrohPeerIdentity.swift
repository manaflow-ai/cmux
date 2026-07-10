/// The stable cryptographic identity of an Iroh endpoint.
///
/// This value identifies the peer independently from every address or relay
/// hint used to reach it. A route may change hints without changing identity.
public struct CmxIrohPeerIdentity: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case endpointID
    }

    /// The Iroh endpoint identifier presented by the route.
    public let endpointID: String

    /// Creates an Iroh peer identity from an endpoint identifier.
    ///
    /// Iroh's canonical display form is exactly 32 bytes encoded as 64
    /// lowercase hexadecimal characters. Other spellings are rejected so one
    /// peer cannot acquire multiple persistence or deduplication identities.
    /// - Parameter endpointID: The stable Iroh endpoint identifier.
    public init(endpointID: String) throws {
        guard Self.isCanonical(endpointID) else {
            throw CmxIrohPeerIdentityError.nonCanonicalEndpointID
        }
        self.endpointID = endpointID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpointID: container.decode(String.self, forKey: .endpointID))
    }

    /// Whether a string is Iroh's canonical EndpointID display form.
    public static func isCanonical(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

/// Validation failures for Iroh peer identity values.
public enum CmxIrohPeerIdentityError: Error, Equatable, Sendable {
    /// The value was not exactly 64 lowercase hexadecimal characters.
    case nonCanonicalEndpointID
}
