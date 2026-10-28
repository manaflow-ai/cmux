import CmuxNextCompat
import Observation

extension DaemonStore {
    /// Waits until the store applied every event up to `sequence` (``DaemonConnection/eventSequence()`` read
    /// after a command's reply) and says whether it did: false at once for no sequence (the connection lost
    /// `ready`: nothing bounds the events), and false when the connection changed since `epoch`
    /// (``connectionEpoch`` read in the same turn as the sequence) before the store got there: its events may
    /// never apply. The one read-your-writes wait; ``applied(through:)`` is its unchecked form.
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
        // connectionEpoch is not observed; every epoch change also sets connectionState, which is.
        for await done in ObservationStream({ (self.appliedSequence >= sequence, self.connectionState) }) {
            if done.0 { return true }
            if connectionEpoch != epoch { return false }
        }
        return appliedSequence >= sequence
    }
}
