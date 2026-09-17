/// Local failures while constructing endpoint-authenticated registration.
public enum CmxIrohRegistrationError: Error, Equatable, Sendable {
    /// A UUID, tag, display name, generation, capability, or hint is invalid.
    case invalidPayload

    /// The encoded registration exceeds the broker request limit.
    case payloadTooLarge

    /// The Iroh secret does not derive the declared EndpointID.
    case endpointIdentityMismatch

    /// The broker challenge identifier or nonce is malformed.
    case invalidChallenge
}
