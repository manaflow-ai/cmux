#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDaemon

/// What the app settles on (`debug.oracle.settle`, p15-oracle.md section 3B), injected by the composition
/// root: Control sees neither the daemon connection, AppKit's frames nor Core Animation.
/// ``init(store:sync:motionIdle:commit:motion:)`` builds the daemon store half.
public struct OracleSettleSources: Sendable {
    /// One sync round trip to the local daemon, its mark carrying the epoch read before the round trip.
    public var sync: @MainActor @Sendable () async -> OracleSyncAttempt
    /// Returns true once the connection epoch is no longer the one given, false when cancelled.
    public var connectionChange: @MainActor @Sendable (Int) async -> Bool
    /// The connection epoch now (for an explicit sequence: read in the turn the request is accepted).
    public var epoch: @MainActor @Sendable () -> Int
    /// The daemon half (p15-oracle-029's `DaemonStore.settle(through:since:)`): returns once the store applied
    /// every event up to the mark and no intent is pending, else the waits still pending (`daemon.applied`,
    /// `daemon.intents`, `daemon.connection`) when the connection changed or the deadline cancelled it.
    public var daemon: @MainActor @Sendable (OracleDaemonMark) async -> [String]
    /// Returns true once no `MotionClock` steps an animator, false when cancelled.
    public var motionIdle: @MainActor @Sendable () async -> Bool
    /// Returns after the next `CommitBoundary`: the Core Animation commit that ends the main run-loop turn.
    public var commit: @MainActor @Sendable () async -> Void
    /// What still keeps the app from settling, read in one main-actor turn when a stage misses the deadline:
    /// `intent:<case>` per pending intent, `motion:<trace>` per running animator. Never private text.
    public var pending: @MainActor @Sendable () -> [String]

    public init(sync: @escaping @MainActor @Sendable () async -> OracleSyncAttempt,
                connectionChange: @escaping @MainActor @Sendable (Int) async -> Bool,
                epoch: @escaping @MainActor @Sendable () -> Int,
                daemon: @escaping @MainActor @Sendable (OracleDaemonMark) async -> [String],
                motionIdle: @escaping @MainActor @Sendable () async -> Bool,
                commit: @escaping @MainActor @Sendable () async -> Void,
                pending: @escaping @MainActor @Sendable () -> [String]) {
        self.sync = sync
        self.connectionChange = connectionChange
        self.epoch = epoch
        self.daemon = daemon
        self.motionIdle = motionIdle
        self.commit = commit
        self.pending = pending
    }

    /// The sources over the app's daemon store: its settle, its connection epoch and change wait, and its pending
    /// intents by case name. The sync round trip, motion and commit come from the app.
    ///
    /// - Parameter motion: The traces of the animators running now.
    @MainActor
    public init(store: DaemonStore, sync: @escaping @MainActor @Sendable () async -> OracleSyncAttempt,
                motionIdle: @escaping @MainActor @Sendable () async -> Bool,
                commit: @escaping @MainActor @Sendable () async -> Void,
                motion: @escaping @MainActor @Sendable () -> [String]) {
        self.init(
            sync: sync,
            connectionChange: { [weak store] epoch in await store?.waitConnectionChange(since: epoch) ?? false },
            epoch: { [weak store] in store?.connectionEpoch ?? 0 },
            daemon: { [weak store] mark in
                guard let store else { return [DaemonSettleWait.connection.rawValue] }
                return await store.settle(through: mark.sequence, since: mark.epoch).map(\.rawValue)
            },
            motionIdle: motionIdle,
            commit: commit,
            pending: { [weak store] in Self.pending(intents: store?.pendingIntents.map { $0.intent } ?? [], motion: motion()) })
    }

    /// The pending list's details: `intent:<case>` per pending intent, then `motion:<trace>` per animator.
    static func pending(intents: [Intent], motion: [String]) -> [String] {
        intents.map { "intent:\($0.caseName)" } + motion.map { "motion:\($0)" }
    }

    /// The outcome of a settle that stopped at `stopped` (stage or wait names), with what is still pending now.
    func outcome(_ sequence: UInt64?, stopped: [String]) async -> OracleSettleOutcome {
        let pending = pending
        let details = await pending()
        return OracleSettleOutcome(sequence: sequence, pending: stopped + details.filter { !stopped.contains($0) })
    }
}

/// How a settle ended: settled when nothing is pending.
struct OracleSettleOutcome: Sendable, Equatable {
    /// The home daemon event sequence the settle covered (nil when the sync barrier missed the deadline).
    var sequence: UInt64?
    var pending: [String]

    var settled: Bool { pending.isEmpty }
}
#endif
