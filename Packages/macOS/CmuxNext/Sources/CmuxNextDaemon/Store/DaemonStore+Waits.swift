import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

extension DaemonStore {
    /// Returns once the store applied every event up to `sequence` (``DaemonConnection/eventSequence()`` read
    /// after a command's reply or a sync round trip), the connection changed since `epoch`, or the task was
    /// cancelled. A continuation resumed by ``advanceAppliedSequence(to:)``, by the end of the batch or event that
    /// changed the connection, and by the end of ``run(connection:scheduler:)``: no observation, timer or poll;
    /// the caller's deadline cancels it (the oracle's settle).
    ///
    /// A connection already changed since `epoch` ends the wait at once: a sequence of another connection says
    /// nothing about this one's. A wait that is parked when its connection drops ends reached when the batch
    /// that carried the drop applied its sequence first (a transport delivers a connection's events before the
    /// drop it synthesizes).
    ///
    /// - Parameters:
    ///   - sequence: The event sequence to reach.
    ///   - epoch: ``connectionEpoch`` read in the same main-actor turn as `sequence`.
    /// - Returns: Why the wait ended.
    public func waitApplied(atLeast sequence: UInt64, since epoch: Int) async -> AppliedWaitResult {
        guard connectionEpoch == epoch else { return .connectionChanged }
        if appliedSequence >= sequence { return .reached }
        // A read-your-writes wait never waits on a script batch's stage: what it needs shows now.
        beginAppliedWait(sequence)
        defer { endAppliedWait(sequence) }
        if appliedSequence >= sequence { return .reached }
        let id = sequenceWaiters.makeID()
        // A cancel ends the wait from the canceller's thread (a cancellable continuation); its entry goes when this
        // function resumes here, on main. A wait dropped unresumed ends as a cancelled one does.
        let result = (try? await withOnceContinuation(cancellation: .cancellable, failingWith: { $0 }) {
            (continuation: OnceContinuation<AppliedWaitResult, OnceContinuationError>) in
            sequenceWaiters.addApplied(id, SequenceWaiters.Applied(sequence: sequence, epoch: epoch, continuation: continuation))
        }) ?? .cancelled
        sequenceWaiters.drop(id)
        return result
    }

    /// Returns true once the intent log is empty (every pending intent echoed, settled or refused; at once when
    /// it is), or false when the task was cancelled. Resumed by the overlay lift that removed the last intent.
    public func waitIntentsIdle() async -> Bool {
        if intentLog.isEmpty { return true }
        let id = sequenceWaiters.makeID()
        // As ``waitApplied(atLeast:since:)``: a cancel ends the wait at once, its entry goes at the resume.
        let idle = (try? await withOnceContinuation(cancellation: .cancellable, failingWith: { $0 }) {
            (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            if intentLog.isEmpty {
                continuation.resume(returning: true)
                return
            }
            sequenceWaiters.addIdle(id, continuation)
        }) ?? false
        sequenceWaiters.drop(id)
        return idle
    }

    /// Returns true once ``connectionEpoch`` is no longer `epoch` (a connect, a drop or a shutdown applied; at once
    /// when it already moved), or false when the task was cancelled. Resumed by the connection change itself: the
    /// oracle's settle waits on it for a daemon that is not connected yet, then runs its sync barrier again.
    ///
    /// - Parameter epoch: The ``connectionEpoch`` the caller found unusable.
    public func waitConnectionChange(since epoch: Int) async -> Bool {
        if connectionEpoch != epoch { return true }
        let id = sequenceWaiters.makeID()
        // As ``waitApplied(atLeast:since:)``: a cancel ends the wait at once, its entry goes at the resume.
        let changed = (try? await withOnceContinuation(cancellation: .cancellable, failingWith: { $0 }) {
            (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            if connectionEpoch != epoch {
                continuation.resume(returning: true)
                return
            }
            sequenceWaiters.addConnection(id, epoch: epoch, continuation)
        }) ?? false
        sequenceWaiters.drop(id)
        return changed
    }

    /// The daemon half of `debug.oracle.settle` (p15-oracle-031 adds the snapshot barrier, MotionClock idle, one
    /// CommitBoundary and the deadline, which cancels this task): the store applied every event up to `sequence`
    /// (the sync barrier's; nil: none), then no intent is pending.
    ///
    /// - Parameters:
    ///   - sequence: The sync barrier's event sequence; nil waits for the intents alone.
    ///   - epoch: ``connectionEpoch`` read in the same main-actor turn as `sequence`.
    /// - Returns: The waits still pending when the task was cancelled or the connection changed; empty once settled.
    public func settle(through sequence: UInt64?, since epoch: Int) async -> [DaemonSettleWait] {
        if let sequence {
            switch await waitApplied(atLeast: sequence, since: epoch) {
            case .reached: break
            case .connectionChanged: return [.connection]
            case .cancelled: return intentLog.isEmpty ? [.applied] : [.applied, .intents]
            }
        }
        return await waitIntentsIdle() ? [] : [.intents]
    }

    /// The applied waits still waiting plus the idle waits (tests).
    var pendingWaitCount: Int { sequenceWaiters.count }

    /// Resumes the applied waits that are over: the store reached their sequence, or their connection changed.
    func resumeAppliedWaits() {
        guard sequenceWaiters.hasApplied else { return }
        for (continuation, result) in sequenceWaiters.takeDueApplied(appliedSequence: appliedSequence, epoch: connectionEpoch) {
            continuation.resume(returning: result)
        }
    }

    /// Resumes the connection waits once the epoch moved.
    func resumeConnectionWaits() {
        for continuation in sequenceWaiters.takeChangedConnection(epoch: connectionEpoch) { continuation.resume(returning: true) }
    }

    /// The connection's event stream ended: no event reaches the applied waits still parked.
    func endAppliedWaits() {
        for continuation in sequenceWaiters.takeAllApplied() { continuation.resume(returning: .connectionChanged) }
    }

    /// Resumes the idle waits once the intent log is empty.
    func resumeIdleWaits() {
        guard sequenceWaiters.hasIdle, intentLog.isEmpty else { return }
        for continuation in sequenceWaiters.takeIdle() { continuation.resume(returning: true) }
    }
}
