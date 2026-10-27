import enum CmuxNextDaemon.DaemonSettleWait // scoped: CmuxNextDaemon also has a JSONValue, which would make this file's ambiguous
public import CmuxNextSettings

/// The read barrier every method accepts (plans/cmux-next/state-ownership.md 4.3).
///
/// `after` is either a number, the `sequence` an earlier app reply printed
/// (`action.run`, `snapshot.get`), or `"sync"`, which first asks the local
/// daemon for the event sequence that covers every write it committed so
/// far (writes the CLI sent to the daemon directly). The request then
/// answers from the first published snapshot that reflects that sequence,
/// within its deadline, so targets resolve against state that includes
/// the caller's writes.
extension ControlRouter {
    func readBarrier(_ after: JSONValue, method: String, deadline: ContinuousClock.Instant) async throws -> ControlSnapshot {
        let sequence = try await barrierSequence(after, method: method, deadline: deadline)
        guard let snapshot = await snapshots.snapshot(reflecting: sequence, deadline: deadline) else {
            var error = ControlError.timeout(method, after: .zero)
            error.data = ["method": .string(method), "after": JSONValue.number(Double(sequence)),
                          "sequence": JSONValue.number(Double(snapshots.current.topology.daemonSequence))]
            throw error
        }
        return snapshot
    }

    /// The home daemon event sequence `after` names: the number itself, or for `"sync"` the sequence a
    /// round trip to the local daemon returns (``registerSyncBarrier(_:)``), within `deadline`.
    func barrierSequence(_ after: JSONValue, method: String, deadline: ContinuousClock.Instant) async throws -> UInt64 {
        if let sequence = Self.explicitSequence(after) { return sequence }
        guard after == .string("sync") else {
            throw ControlError.invalidParams(ControlStrings.text("control.error.afterShape",
                                                                 "after must be a sequence number from an earlier reply or \"sync\""))
        }
        // Not registered yet (the socket serves before the App wires the
        // daemon): answering from the current snapshot would skip the sync.
        guard let barrier = syncBarrier else {
            throw ControlError(code: "unavailable", message: ControlStrings.text("control.error.syncBarrierUnavailable",
                                                                                 "after: \"sync\" is not available yet; retry"))
        }
        return try await ControlDeadline.shared.run(method: method, deadline: deadline) { try await barrier() }
    }

    /// The sequence number `after` gives itself, nil when it is `"sync"` or not a sequence.
    static func explicitSequence(_ after: JSONValue) -> UInt64? {
        switch after {
        // `Double(UInt64.max)` rounds up to 2^64, which `UInt64` cannot hold;
        // a full-width sequence goes as a string.
        // UInt64(exactly:) is nil for fractions, negatives, NaN, infinity and 2^64.
        case .number(let value): UInt64(exactly: value)
        case .string(let text): UInt64(text, radix: 10)
        default: nil
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The refactor oracle's checkpoint barrier (`debug.oracle.settle`, p15-oracle.md section 3B): stages one
/// after the other, all bounded by one deadline. A stage that misses it ends the settle with the pending
/// list, which the runner records as Timeout. Chrome's shape: content::WaitForLoadStop and
/// RenderFrameSubmissionObserver (content/public/test/browser_test_utils.cc) wait on the producer's own
/// signal, never on a polled condition.
extension ControlRouter {
    /// Settles the app through home daemon event `after`:
    /// 1. the mark: for `"sync"`, a sync round trip with the connection epoch read before it, tried again on
    ///    each connection change while the daemon cannot answer (``OracleSettleSources/sync``); for a number,
    ///    that sequence with the epoch read in the first main-actor turn after the request is accepted;
    /// 2. ``ControlSnapshot/reflects(_:)`` holds for that ``ControlSequenceBarrier``;
    /// 3. the daemon store applied the mark on its connection and no intent is pending
    ///    (``OracleSettleSources/daemon``); a `"sync"` mark whose connection changed meanwhile syncs again;
    /// 4. no `MotionClock` steps an animator (``OracleSettleSources/motionIdle``);
    /// 5. one `CommitBoundary` passed (``OracleSettleSources/commit``): the settled state is committed.
    ///
    /// - Throws: `invalid_params` for an `after` that is neither a sequence nor `"sync"`.
    ///   A missed deadline is not an error: it is the outcome's pending list.
    func oracleSettle(after: JSONValue, sources: OracleSettleSources,
                      deadline: ContinuousClock.Instant) async throws -> OracleSettleOutcome {
        let method = OracleSettleControl.settle
        var explicit: OracleDaemonMark?
        if let sequence = Self.explicitSequence(after) {
            explicit = OracleDaemonMark(sequence: sequence, epoch: await sources.epoch())
        } else if after != .string("sync") {
            throw ControlError.invalidParams(ControlStrings.text("control.error.afterShape",
                                                                 "after must be a sequence number from an earlier reply or \"sync\""))
        }
        var mark = explicit
        if mark == nil { mark = await Self.syncMark(sources, method: method, deadline: deadline) }
        // Each pass awaits a new sync mark: a sync mark whose connection went away before the store applied it
        // is redone on the next connection, which numbers its own events.
        while let current = mark {
            switch await settlePass(through: current, sources: sources, method: method, deadline: deadline) {
            case .ended(let outcome):
                return outcome
            case .connectionChanged(let outcome):
                guard explicit == nil, ContinuousClock.now < deadline else { return outcome }
                mark = await Self.syncMark(sources, method: method, deadline: deadline)
            }
        }
        return await sources.outcome(nil, stopped: [OracleSettleControl.Stage.sync])
    }

    /// How the stages after the mark ended.
    private enum SettlePass {
        case ended(OracleSettleOutcome)
        /// The store's settle found the mark's connection gone (its outcome, should no sync follow).
        case connectionChanged(OracleSettleOutcome)
    }

    /// The stages after the mark: the snapshot barrier, the store, motion, one commit.
    private func settlePass(through mark: OracleDaemonMark, sources: OracleSettleSources, method: String,
                            deadline: ContinuousClock.Instant) async -> SettlePass {
        guard await snapshots.snapshot(reflecting: ControlSequenceBarrier(home: mark.sequence), deadline: deadline) != nil else {
            return .ended(await sources.outcome(mark.sequence, stopped: [OracleSettleControl.Stage.snapshot]))
        }
        let daemon = sources.daemon
        let waits = await Self.untilDeadline(deadline, method: method, { await daemon(mark) })
        if waits == [DaemonSettleWait.connection.rawValue] { return .connectionChanged(await sources.outcome(mark.sequence, stopped: waits)) }
        if !waits.isEmpty { return .ended(await sources.outcome(mark.sequence, stopped: waits)) }
        let motionIdle = sources.motionIdle
        guard await Self.untilDeadline(deadline, method: method, { await motionIdle() }) else {
            return .ended(await sources.outcome(mark.sequence, stopped: [OracleSettleControl.Stage.motion]))
        }
        let commit = sources.commit
        guard (try? await ControlDeadline.shared.run(method: method, deadline: deadline, { await commit() })) != nil else {
            return .ended(await sources.outcome(mark.sequence, stopped: [OracleSettleControl.Stage.commit]))
        }
        return .ended(OracleSettleOutcome(sequence: mark.sequence, pending: []))
    }

    /// A sync mark within `deadline`, nil when it passes first. While the daemon cannot answer, each next try
    /// waits for the connection to change (``OracleSettleSources/connectionChange``).
    private static func syncMark(_ sources: OracleSettleSources, method: String, deadline: ContinuousClock.Instant) async -> OracleDaemonMark? {
        // `try?` flattens: nil at the deadline and when the sync was cancelled.
        try? await ControlDeadline.shared.run(method: method, deadline: deadline) { () async -> OracleDaemonMark? in
            var attempt = await sources.sync()
            while case .unavailable(let epoch) = attempt {
                guard await sources.connectionChange(epoch) else { return nil }
                attempt = await sources.sync()
            }
            guard case .reached(let mark) = attempt else { return nil }
            return mark
        }
    }

    /// Runs `stage` until it returns or `deadline` passes, when it is cancelled and its own answer to the
    /// cancel is the result: a stage that honors cancellation (the store's settle, the motion idle wait) says
    /// what it still waited for, which a dropped result would lose.
    private static func untilDeadline<T: Sendable>(_ deadline: ContinuousClock.Instant, method: String,
                                                   _ stage: @escaping @MainActor @Sendable () async -> T) async -> T {
        // task-owner: this stage; cancelled at the deadline and awaited before the settle goes on
        let work = Task { @MainActor in await stage() }
        _ = try? await ControlDeadline.shared.run(method: method, deadline: deadline) {
            await withTaskCancellationHandler { _ = await work.value } onCancel: { work.cancel() }
        }
        work.cancel()
        return await work.value
    }
}
#endif
