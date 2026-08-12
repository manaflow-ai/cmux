/// Owns the close handle for a peer session while discovery, dialing, and
/// admission are still in flight.
///
/// Retirement can race session construction. A candidate registered after its
/// generation retired is closed immediately and never becomes installable.
actor CmxConnectivityPendingSessionRetirement {
    private var candidate: (any CmxConnectivitySession)?
    private var retired = false

    func register(_ candidate: any CmxConnectivitySession) async throws {
        guard !retired else {
            await candidate.close()
            throw CmxConnectivityEngineError.superseded
        }
        self.candidate = candidate
    }

    func finish() {
        candidate = nil
    }

    /// Cancels admission by closing its whole parent session when available.
    /// A late candidate observes `retired` in ``register(_:)`` and closes there.
    func retire() async {
        guard !retired else { return }
        retired = true
        let candidateToClose = candidate
        candidate = nil
        await candidateToClose?.close()
    }
}
