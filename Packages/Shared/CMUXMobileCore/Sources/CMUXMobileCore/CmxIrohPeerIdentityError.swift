/// Validation failures for Iroh peer identity values.
public enum CmxIrohPeerIdentityError: Error, Equatable, Sendable {
    /// The value was not exactly 64 lowercase hexadecimal characters.
    case nonCanonicalEndpointID
}
