extension DaemonStore {
    /// Returns once the store applied every event up to `sequence` (``DaemonConnection/eventSequence()`` read
    /// after a command's reply or a sync round trip), the connection changed since `epoch`, or the task was
    /// cancelled. A continuation resumed by ``advanceAppliedSequence(to:)`` and by the connection change itself:
    /// no observation, timer or poll; the caller's deadline cancels it (the oracle's settle, p15-oracle-031).
    ///
    /// - Parameters:
    ///   - sequence: The event sequence to reach.
    ///   - epoch: ``connectionEpoch`` read with `sequence`; nil takes the current one.
    /// - Returns: Why the wait ended.
    public func waitApplied(atLeast sequence: UInt64, since epoch: Int? = nil) async -> AppliedWaitResult {
        let epoch = epoch ?? connectionEpoch
        guard connectionEpoch == epoch else { return .connectionChanged }
        if appliedSequence >= sequence { return .reached }
        // A read-your-writes wait never waits on a script batch's stage: what it needs shows now.
        beginAppliedWait(sequence)
        defer { endAppliedWait(sequence) }
        if appliedSequence >= sequence { return .reached }
        let id = storeWaiters.makeID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AppliedWaitResult, Never>) in
                if Task.isCancelled { return continuation.resume(returning: .cancelled) }
                storeWaiters.addApplied(id, StoreWaiters.Applied(sequence: sequence, epoch: epoch, continuation: continuation))
            }
        } onCancel: {
            // task-owner: one hop to the store's actor to resume this cancelled wait's continuation
            Task { @MainActor in self.storeWaiters.cancel(id) }
        }
    }

    /// Returns true once the intent log is empty (every pending intent echoed, settled or refused; at once when
    /// it is), or false when the task was cancelled. Resumed by the overlay lift that removed the last intent.
    public func waitIntentsIdle() async -> Bool {
        if intentLog.isEmpty { return true }
        let id = storeWaiters.makeID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { return continuation.resume(returning: false) }
                if intentLog.isEmpty { return continuation.resume(returning: true) }
                storeWaiters.addIdle(id, continuation)
            }
        } onCancel: {
            // task-owner: one hop to the store's actor to resume this cancelled wait's continuation
            Task { @MainActor in self.storeWaiters.cancel(id) }
        }
    }

    /// The daemon half of `debug.oracle.settle` (p15-oracle-031 adds the snapshot barrier, MotionClock idle, one
    /// CommitBoundary and the deadline, which cancels this task): the store applied every event up to `sequence`
    /// (the sync barrier's; nil: none), then no intent is pending.
    ///
    /// - Returns: The waits still pending when the task was cancelled or the connection changed; empty once settled.
    public func settle(through sequence: UInt64?) async -> [DaemonSettleWait] {
        if let sequence {
            switch await waitApplied(atLeast: sequence) {
            case .reached: break
            case .connectionChanged: return [.connection]
            case .cancelled: return intentLog.isEmpty ? [.applied] : [.applied, .intents]
            }
        }
        return await waitIntentsIdle() ? [] : [.intents]
    }

    /// The applied waits still waiting plus the idle waits (tests).
    var pendingWaitCount: Int { storeWaiters.count }

    /// Resumes the applied waits the applied sequence or a connection change ended.
    func resumeAppliedWaits() {
        guard storeWaiters.hasApplied else { return }
        for (continuation, result) in storeWaiters.takeDueApplied(appliedSequence: appliedSequence, epoch: connectionEpoch) {
            continuation.resume(returning: result)
        }
    }

    /// Resumes the idle waits once the intent log is empty.
    func resumeIdleWaits() {
        guard storeWaiters.hasIdle, intentLog.isEmpty else { return }
        for continuation in storeWaiters.takeIdle() { continuation.resume(returning: true) }
    }
}
