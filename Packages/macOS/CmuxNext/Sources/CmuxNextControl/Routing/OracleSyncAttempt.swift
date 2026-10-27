#if DEBUG || CMUX_BENCH_HOOKS
/// A home daemon event sequence with the connection it belongs to: ``DaemonStore/connectionEpoch`` read in the
/// main-actor turn the sequence was read (p15-oracle-029's `settle(through:since:)` contract).
public struct OracleDaemonMark: Sendable, Equatable {
    public var sequence: UInt64
    public var epoch: Int

    public init(sequence: UInt64, epoch: Int) {
        self.sequence = sequence
        self.epoch = epoch
    }
}

/// One try of the settle's sync barrier.
public enum OracleSyncAttempt: Sendable, Equatable {
    /// The local daemon answered: every write it committed before the reply is at or below the mark's sequence.
    case reached(OracleDaemonMark)
    /// The daemon cannot answer on the connection of `epoch` (none yet, a drop, a failed round trip): the settle
    /// tries again once the connection changes (``OracleSettleSources/connectionChange``), within its deadline.
    case unavailable(epoch: Int)
}
#endif
