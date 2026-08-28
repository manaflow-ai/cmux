/// Failures specific to relay policy orchestration.
public enum CmxIrohRelayPolicyServiceError: Error, Equatable, Sendable {
    /// No broker was injected for a network-backed operation.
    case brokerUnavailable

    /// A preference revision rolled back or equivocated.
    case preferenceRollback

    /// A newer policy operation superseded this suspended operation.
    case superseded
}
