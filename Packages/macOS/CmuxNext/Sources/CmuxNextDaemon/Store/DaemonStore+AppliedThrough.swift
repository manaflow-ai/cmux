extension DaemonStore {
    /// Waits until the store applied every event up to `sequence` (``DaemonConnection/eventSequence()`` read
    /// after a command's reply) and says whether it did. The read-your-writes wait.
    ///
    /// It holds once ``appliedSequence`` reaches `sequence`. A drop the daemon's stream reports holds a wait for
    /// the events routed before it: the drop's envelope has the connection's last sequence and applies after
    /// them. It does not hold for no sequence (the connection lost `ready`: nothing bounds the events), when the
    /// connection changed since `epoch` (``connectionEpoch`` read before the sequence), or when the connection
    /// ends during the wait with no such envelope: marked failed (``markFailed(_:)``) or its run finished
    /// (`close()`). Every end of a connection moves the epoch and runs the waiters
    /// (``DaemonConnectionChange``), so the wait never outlives its connection. A cancelled wait returns false
    /// at once. Event-driven: one waiter in the store's applied-waiter list, no observation loop.
    ///
    /// - Parameters:
    ///   - sequence: The event sequence after the reply.
    ///   - epoch: ``connectionEpoch`` read before it.
    /// - Returns: Whether the store holds every event up to `sequence`.
    public func appliedThrough(_ sequence: UInt64?, since epoch: Int) async -> Bool {
        guard let sequence else { return false }
        if appliedSequence >= sequence { return true }
        guard connectionEpoch == epoch, !Task.isCancelled else { return false }
        let id = nextAppliedWaiterID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                self.appliedWaiters.append(AppliedWaiter(id: id, transaction: nil, sequence: sequence) { held in
                    done.resume(returning: held)
                })
            }
        } onCancel: {
            // task-owner: one hop to the main actor to end this cancelled wait (its waiter runs, not held)
            Task { @MainActor [weak self] in self?.cancelAppliedWaiter(id) }
        }
    }
}
