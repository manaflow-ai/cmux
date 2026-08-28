/// Validation failures for an Iroh endpoint bind configuration.
public enum CmxIrohEndpointConfigurationError: Error, Equatable, Sendable {
    /// The relay fleet is larger than the endpoint policy permits.
    case tooManyRelays(Int)

    /// The endpoint implementation cannot apply a complete profile replacement.
    case unsupportedRelayProfileReplacement
}
