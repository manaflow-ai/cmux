/// Local authorization result for an authenticated Iroh connection.
public enum CmxIrohAdmissionAuthorization: Equatable, Sendable {
    /// The exact TLS-bound iOS binding may use the application transport.
    case accepted(
        CmxIrohAdmittedPeer,
        onlineLease: CmxIrohOnlineAdmissionLease?
    )
    /// Admission failed with a non-sensitive protocol code.
    case denied(code: UInt16)

    var wireDecision: CmxIrohAdmissionDecision {
        switch self {
        case .accepted:
            .accepted
        case let .denied(code):
            .denied(code: code)
        }
    }
}
