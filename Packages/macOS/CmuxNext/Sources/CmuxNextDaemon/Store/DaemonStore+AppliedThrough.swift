extension DaemonStore {
    /// Waits until the store applied every event up to `sequence` (``DaemonConnection/eventSequence()`` read
    /// after a command's reply) and says whether it did: false at once for no sequence (the connection lost
    /// `ready`: nothing bounds the events), and false when the connection changed since `epoch`
    /// (``connectionEpoch`` read in the same turn as the sequence) before the store got there: its events may
    /// never apply. The one read-your-writes wait, ``waitApplied(atLeast:since:)``, read as held or not;
    /// ``applied(through:)`` is its unchecked form.
    ///
    /// - Parameters:
    ///   - sequence: The event sequence after the reply.
    ///   - epoch: ``connectionEpoch`` read with it.
    /// - Returns: Whether the store holds every event up to `sequence`.
    public func appliedThrough(_ sequence: UInt64?, since epoch: Int) async -> Bool {
        guard let sequence else { return false }
        return await waitApplied(atLeast: sequence, since: epoch) == .reached
    }
}
