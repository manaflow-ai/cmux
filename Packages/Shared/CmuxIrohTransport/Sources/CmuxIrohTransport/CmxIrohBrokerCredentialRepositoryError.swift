/// Validation failures owned by durable Iroh broker state.
public enum CmxIrohBrokerCredentialRepositoryError: Error, Equatable, Sendable {
    /// The account or app-instance scope is malformed.
    case invalidScope

    /// Broker binding metadata is malformed.
    case invalidBinding

    /// Binding metadata does not belong to the requested app-instance scope.
    case bindingScopeMismatch

    /// Relay credentials were saved before their exact binding metadata.
    case bindingNotStored

    /// The supplied binding differs from the active broker binding.
    case bindingMismatch

    /// The credential does not cover exactly the configured managed relay fleet.
    case relayFleetMismatch

    /// The relay token or its lifetime is malformed or no longer fresh.
    case invalidRelayCredential
}
