enum SecondaryMacEstablishmentOutcome {
    case connected
    case transientFailure
    case permanentFailure
    /// Scope or ownership changed while the attempt was in flight.
    case superseded
}
