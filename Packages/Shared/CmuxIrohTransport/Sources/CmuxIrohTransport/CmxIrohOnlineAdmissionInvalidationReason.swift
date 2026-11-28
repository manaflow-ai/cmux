/// Why an admitted online lease stopped authorizing its live host session.
public enum CmxIrohOnlineAdmissionInvalidationReason: Sendable, Equatable {
    /// The signed lease reached its expiration time.
    case leaseExpired

    /// Local or broker policy denied or revoked one of the lease bindings.
    case denied

    /// Online broker revalidation failed for a non-connectivity reason.
    case revalidationFailed
}
