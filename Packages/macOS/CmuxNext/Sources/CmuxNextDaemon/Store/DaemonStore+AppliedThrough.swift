import CmuxNextCompat
import Observation

extension DaemonStore {
    /// Waits until the store applied every event up to `sequence` (``DaemonConnection/eventSequence()`` read
    /// after a command's reply) and says whether it did: false at once for no sequence (the connection lost
    /// `ready`: nothing bounds the events), and false when the connection changed since `epoch`
    /// (``connectionEpoch`` read in the same turn as the sequence) before the store got there: its events may
    /// never apply. The one read-your-writes wait; ``applied(through:)`` is its unchecked form.
    ///
    /// Bounded by the store's own liveness, not by a clock: when the store stopped catching up (its snapshot
    /// retries are spent and it waits for the next daemon event, ``needsResync``), the wait asks for one resync
    /// itself, and ends as not held when the store still cannot catch up. Waiting on would wait for an event the
    /// waiting caller is what would cause (#32408: a classic upgrade froze at 130 of 512 workspaces).
    ///
    /// - Parameters:
    ///   - sequence: The event sequence after the reply.
    ///   - epoch: ``connectionEpoch`` read with it.
    /// - Returns: Whether the store holds every event up to `sequence`.
    public func appliedThrough(_ sequence: UInt64?, since epoch: Int) async -> Bool {
        guard let sequence else { return false }
        if appliedSequence >= sequence { return true }
        guard connectionEpoch == epoch else { return false }
        // A read-your-writes wait never waits on a script batch's stage: what it needs shows now.
        beginAppliedWait(sequence)
        defer { endAppliedWait(sequence) }
        if appliedSequence >= sequence { return true }
        var asked = false
        // connectionEpoch is not observed; every epoch change also sets connectionState, which is.
        for await done in ObservationStream({ (self.appliedSequence >= sequence, self.connectionState, self.needsResync) }) {
            if done.0 { return true }
            if connectionEpoch != epoch { return false }
            guard needsResync else { continue }
            // Stopped catching up: this wait is the demand the store waits for, once. A resync that starts clears
            // `needsResync`; one that fails past its budget again sets it, and the wait ends.
            if asked { return false }
            asked = true
            resync()
            if needsResync { return false }
        }
        return appliedSequence >= sequence
    }
}
