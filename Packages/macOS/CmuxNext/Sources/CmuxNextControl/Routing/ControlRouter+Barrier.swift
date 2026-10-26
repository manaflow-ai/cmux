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
        let sequence: UInt64
        switch after {
        // `Double(UInt64.max)` rounds up to 2^64, which `UInt64` cannot hold;
        // a full-width sequence goes as a string.
        // UInt64(exactly:) is nil for fractions, negatives, NaN, infinity and 2^64.
        case .number(let value) where UInt64(exactly: value) != nil:
            sequence = UInt64(exactly: value) ?? 0
        case .string(let text) where UInt64(text, radix: 10) != nil:
            sequence = UInt64(text, radix: 10) ?? 0
        case .string("sync"):
            // Not registered yet (the socket serves before the App wires the
            // daemon): answering from the current snapshot would skip the sync.
            guard let barrier = syncBarrier else {
                throw ControlError(code: "unavailable", message: ControlStrings.text("control.error.syncBarrierUnavailable",
                                                                                     "after: \"sync\" is not available yet; retry"))
            }
            sequence = try await ControlDeadline.shared.run(method: method, deadline: deadline) { try await barrier() }
        default:
            throw ControlError.invalidParams(ControlStrings.text("control.error.afterShape",
                                                                 "after must be a sequence number from an earlier reply or \"sync\""))
        }
        return sequence
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The refactor oracle's checkpoint barrier (`debug.oracle.settle`, p15-oracle.md section 3B): stages one
/// after the other, all bounded by one deadline. A stage that misses it ends the settle with the pending
/// list, which the runner records as Timeout. Chrome's shape: content::WaitForLoadStop and
/// RenderFrameSubmissionObserver (content/public/test/browser_test_utils.cc) wait on the producer's own
/// signal, never on a polled condition.
extension ControlRouter {
    /// Settles the app through home daemon event `after` (a sequence number, or `"sync"`):
    /// 1. ``ControlSnapshot/reflects(_:)`` holds for that ``ControlSequenceBarrier``;
    /// 2. the daemon store applied it and no intent is pending (``OracleSettleSources/daemon``);
    /// 3. no `MotionClock` steps an animator (``OracleSettleSources/motionIdle``);
    /// 4. one `CommitBoundary` passed (``OracleSettleSources/commit``): the settled state is committed.
    ///
    /// - Throws: `invalid_params` for a bad `after`, `unavailable` while the sync barrier cannot run.
    ///   A missed deadline is not an error: it is the outcome's pending list.
    func oracleSettle(after: JSONValue, sources: OracleSettleSources,
                      deadline: ContinuousClock.Instant) async throws -> OracleSettleOutcome {
        let method = OracleSettleControl.settle
        let sequence: UInt64
        do {
            sequence = try await barrierSequence(after, method: method, deadline: deadline)
        } catch let error as ControlError where error.code == "timeout" {
            return await sources.outcome(nil, stopped: [OracleSettleControl.Stage.sync])
        }
        guard await snapshots.snapshot(reflecting: ControlSequenceBarrier(home: sequence), deadline: deadline) != nil else {
            return await sources.outcome(sequence, stopped: [OracleSettleControl.Stage.snapshot])
        }
        let daemon = sources.daemon
        guard let waits = try? await ControlDeadline.shared.run(method: method, deadline: deadline, { await daemon(sequence) }) else {
            return await sources.outcome(sequence, stopped: [OracleSettleControl.Stage.daemon])
        }
        if !waits.isEmpty { return await sources.outcome(sequence, stopped: waits) }
        let motionIdle = sources.motionIdle
        guard (try? await ControlDeadline.shared.run(method: method, deadline: deadline, { await motionIdle(deadline) })) == true else {
            return await sources.outcome(sequence, stopped: [OracleSettleControl.Stage.motion])
        }
        let commit = sources.commit
        guard (try? await ControlDeadline.shared.run(method: method, deadline: deadline, { await commit() })) != nil else {
            return await sources.outcome(sequence, stopped: [OracleSettleControl.Stage.commit])
        }
        return OracleSettleOutcome(sequence: sequence, pending: [])
    }
}
#endif
