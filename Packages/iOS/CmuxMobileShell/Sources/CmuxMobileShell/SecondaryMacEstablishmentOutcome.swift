enum SecondaryMacEstablishmentOutcome: Sendable {
    case connected
    case transientFailure
    case permanentFailure
    /// Scope or ownership changed while the attempt was in flight.
    case superseded
}

struct SecondaryMacReconciliationResult: Sendable {
    let macDeviceID: String
    let establishmentOutcome: SecondaryMacEstablishmentOutcome?
}
