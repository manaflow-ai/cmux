internal actor BackendServiceReadinessDeadline {
    private enum State {
        case pending
        case completed
        case expired
    }

    private var state = State.pending

    /// Claims a completed handshake after sampling time inside this actor.
    func complete(
        clock: ContinuousClock,
        before absoluteDeadline: ContinuousClock.Instant
    ) -> Bool {
        guard case .pending = state else { return false }
        guard clock.now < absoluteDeadline else { return false }
        state = .completed
        return true
    }

    /// Claims the deadline before a handshake completes.
    func expire() -> Bool {
        guard case .pending = state else { return false }
        state = .expired
        return true
    }

    func hasExpired() -> Bool {
        guard case .expired = state else { return false }
        return true
    }
}
