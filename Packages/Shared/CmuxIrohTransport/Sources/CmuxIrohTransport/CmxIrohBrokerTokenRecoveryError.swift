public import CMUXMobileCore

/// A platform auth owner can use this error to preserve the outcome of the
/// one broker-401 recovery attempt across the transport boundary.
///
/// The transport package deliberately does not depend on an auth coordinator.
/// Callers map their coordinator's errors to this small vocabulary, allowing
/// every broker client (legacy and irx) to apply the same retry policy without
/// leaking auth implementation types into the wire layer.
public enum CmxIrohBrokerTokenRecoveryError: Error, Equatable, Sendable {
    /// The refresh credential is definitively rejected; sign-in is required.
    case authenticationRequired

    /// The auth store or refresh endpoint was unavailable temporarily.
    case transient
}

extension CmxIrohBrokerTokenRecoveryError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .authenticationRequired:
            .authorizationFailed
        case .transient:
            .offline
        }
    }
}
