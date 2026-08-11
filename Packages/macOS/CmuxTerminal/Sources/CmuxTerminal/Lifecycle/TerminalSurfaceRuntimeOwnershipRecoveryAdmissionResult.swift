/// Result of synchronous native-surface ownership admission with recovery.
nonisolated enum TerminalSurfaceRuntimeOwnershipRecoveryAdmissionResult: Equatable, Sendable {
    /// Ownership was admitted immediately.
    case reserved(TerminalSurfaceRuntimeOwnershipReservation)

    /// The bounded recovery queue retained the request for a later grant.
    case deferred

    /// The bounded recovery queue rejected the request without retaining it.
    case rejected

    /// Every bounded close worker exceeded its watchdog deadline.
    case closeTeardownStalled
}
