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
        // A read-your-writes wait never waits on a script batch's stage: what it needs shows now.
        if let stage, stage.holds(through: sequence, echo: transaction) { stage.commitAll() }
        if confirmedTransactions.contains(transaction) { return body() }
        if let sequence, appliedSequence >= sequence { return body() }
        appliedWaiters.append(AppliedWaiter(transaction: transaction, sequence: sequence, body: body))
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
    /// daemon truth); `all` runs every waiter (the connection is gone: the
    /// store will hold nothing newer for them).
    func runAppliedWaiters(_ transaction: ClientTransactionID?, snapshot: Bool = false, all: Bool = false) {
        // Inside an apply, the caller flushes once the visible state is back.
        guard !appliedWaiters.isEmpty, applyDepth == 0, !overlayLifted else { return }
        let isDue: (AppliedWaiter) -> Bool = { [appliedSequence, confirmedTransactions] waiter in
            if all { return true }
            if let transaction { return waiter.transaction == transaction }
            if confirmedTransactions.contains(waiter.transaction) { return true }
            guard let sequence = waiter.sequence else { return snapshot }
            return appliedSequence >= sequence
        }
        let due = appliedWaiters.filter(isDue)
        guard !due.isEmpty else { return }
        appliedWaiters.removeAll(where: isDue)
        for waiter in due { waiter.body() }
    }

    /// Runs the due waiters, or every waiter after a disconnect.
    func flushAppliedWaiters() {
        guard applyDepth == 0, !overlayLifted else { return }
        let all = drainAppliedWaiters
        drainAppliedWaiters = false
        runAppliedWaiters(nil, all: all)
    }
}
