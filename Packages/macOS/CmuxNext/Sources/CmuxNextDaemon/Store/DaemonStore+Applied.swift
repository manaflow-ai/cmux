import Foundation

/// Transaction echoes and read-your-writes waiters: what runs once the
/// store holds the daemon's result of a command.
extension DaemonStore {
    /// The daemon echoed `transaction`: record it and run its waiters.
    func confirm(_ transaction: ClientTransactionID) {
        guard !confirmedTransactions.contains(transaction) else { return }
        confirmedTransactions.append(transaction)
        if confirmedTransactions.count > transactionLimit {
            confirmedTransactions.removeFirst(confirmedTransactions.count - transactionLimit)
        }
        onTransactionConfirmed?(transaction)
        // Inside a batch the waiters run once the whole batch is applied.
        if applyDepth == 0 { runAppliedWaiters(transaction) }
    }

    /// Runs `body` once the store holds the daemon's result of
    /// `transaction`: when its echo is applied, at once if it already was,
    /// when the store applied every event up to `sequence` (a write barrier,
    /// `DaemonConnection.eventSequence()` taken after the command's reply:
    /// a command that changed nothing echoes nothing), or at the next
    /// snapshot (daemon truth replaces the tree).
    public func whenApplied(_ transaction: ClientTransactionID, reaching sequence: UInt64? = nil,
                            _ body: @escaping @MainActor () -> Void) {
        if confirmedTransactions.contains(transaction) { return body() }
        if let sequence, appliedSequence >= sequence { return body() }
        appliedWaiters.append(AppliedWaiter(id: nextAppliedWaiterID(), transaction: transaction, sequence: sequence) { _ in body() })
    }

    /// A new ``AppliedWaiter/id``.
    func nextAppliedWaiterID() -> UInt64 {
        appliedWaiterSerial += 1
        return appliedWaiterSerial
    }

    /// Ends the wait `id` (its task was cancelled) as not held, when it still waits.
    func cancelAppliedWaiter(_ id: UInt64) {
        guard let index = appliedWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = appliedWaiters.remove(at: index)
        waiter.body(false)
    }

    /// Returns once the store holds the daemon's result of `transaction` (``whenApplied(_:reaching:_:)``
    /// with the connection's event sequence after the reply as the barrier); at once without a
    /// connection. A create pressed on a create in flight waits on it, so it names the daemon's pane.
    public func applied(_ transaction: ClientTransactionID, connection: DaemonConnection?) async {
        guard let connection, let sequence = await connection.eventSequence() else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            whenApplied(transaction, reaching: sequence) { done.resume() }
        }
    }

    /// Runs the waiters that are due: for `transaction`; or (nil) every
    /// waiter whose echo was applied or whose barrier the applied sequence
    /// reached; `snapshot` adds waiters without a barrier (a snapshot is
    /// daemon truth); `ending` (the connection is gone: the store will hold
    /// nothing newer for them) adds every waiter except one for a sequence
    /// past that bound (the next link's). Each runs held, except one that
    /// `ending` runs before the store reached its echo or barrier.
    func runAppliedWaiters(_ transaction: ClientTransactionID?, snapshot: Bool = false, ending: UInt64? = nil) {
        // Inside an apply, the caller flushes once the visible state is back.
        guard !appliedWaiters.isEmpty, applyDepth == 0, !overlayLifted else { return }
        let reached: (AppliedWaiter) -> Bool = { [appliedSequence, confirmedTransactions] waiter in
            if let echo = waiter.transaction, confirmedTransactions.contains(echo) { return true }
            guard let sequence = waiter.sequence else { return false }
            return appliedSequence >= sequence
        }
        let isDue: (AppliedWaiter) -> Bool = { waiter in
            if let ending { return reached(waiter) || (waiter.sequence ?? 0) <= ending }
            if let transaction { return waiter.transaction == transaction }
            return reached(waiter) || (snapshot && waiter.sequence == nil)
        }
        let due = appliedWaiters.filter(isDue).map { (body: $0.body, held: ending == nil || reached($0)) }
        guard !due.isEmpty else { return }
        appliedWaiters.removeAll(where: isDue)
        for waiter in due { waiter.body(waiter.held) }
    }

    /// Records that the connection ended: the next flush runs every waiter
    /// for a sequence at or below `bound` (``DaemonConnectionChange``).
    func endAppliedWaits(through bound: UInt64) {
        appliedWaitsEndThrough = max(appliedWaitsEndThrough ?? 0, bound)
    }

    /// Runs the due waiters, or every waiter of an ended connection.
    func flushAppliedWaiters() {
        guard applyDepth == 0, !overlayLifted else { return }
        let ending = appliedWaitsEndThrough
        appliedWaitsEndThrough = nil
        runAppliedWaiters(nil, ending: ending)
    }

    /// The store gave up catching up (``resync(seedAgents:)`` spent its retry
    /// budget): it reaches no sequence past ``appliedSequence`` until the next
    /// daemon event, which may never come on an idle daemon. Every waiter for
    /// such a sequence ends now, not held, as a connection end runs them; an
    /// echo-only waiter keeps waiting (its echo is an event, and an event
    /// resyncs). A new wait meanwhile asks for one snapshot
    /// (``appliedThrough(_:since:)``).
    func endStalledAppliedWaits() {
        guard applyDepth == 0, !overlayLifted else { return }
        let stalled: (AppliedWaiter) -> Bool = { [appliedSequence, confirmedTransactions] waiter in
            guard let sequence = waiter.sequence, sequence > appliedSequence else { return false }
            if let echo = waiter.transaction, confirmedTransactions.contains(echo) { return false }
            return true
        }
        let due = appliedWaiters.filter(stalled)
        guard !due.isEmpty else { return }
        appliedWaiters.removeAll(where: stalled)
        for waiter in due { waiter.body(false) }
    }
}
