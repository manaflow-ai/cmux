extension DaemonStore {
    /// Waits until the store applied every event up to `sequence` (``DaemonConnection/eventSequence()`` read
    /// after a command's reply) and says whether it did. The read-your-writes wait.
    ///
    /// It holds once ``appliedSequence`` reaches `sequence`. A drop the daemon's stream reports holds a wait for
    /// the events routed before it: the drop's envelope has the link's last sequence and applies after them;
    /// a wait for a later link's sequence (read after a reconnect) is not that link's and stays for its own
    /// events. It does not hold for no sequence (the connection lost `ready`: nothing bounds the events), when
    /// the connection changed since `epoch` (``connectionEpoch`` read before the sequence), when the connection
    /// ends during the wait with no such envelope (marked failed, ``markFailed(_:)``, or its run finished,
    /// `close()`), or when the store gives up catching up (a snapshot that failed past its retry budget, on a
    /// daemon that may send no further event). Every end of a connection moves the epoch and runs the waiters
    /// (``DaemonConnectionChange``), so the wait never outlives its connection. A wait taken while the store
    /// has given up asks for one snapshot, and ends not held when that fails too. A cancelled wait returns
    /// false at once. Event-driven: one waiter in the store's applied-waiter list, no observation loop.
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
                // The store gave up catching up (``endStalledAppliedWaits()``) and no event may come to resync it:
                // this wait asks for the snapshot that reaches it; one that fails ends it, not held.
                if self.needsResync, !self.isResyncing, self.resyncRetry == nil, self.driver != nil { self.resync() }
            }
        } onCancel: {
            // task-owner: one hop to the main actor to end this cancelled wait (its waiter runs, not held)
            Task { @MainActor [weak self] in self?.cancelAppliedWaiter(id) }
        }
    }
}
