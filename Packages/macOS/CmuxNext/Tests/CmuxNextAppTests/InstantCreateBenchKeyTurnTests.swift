import CmuxNextCompat
@testable import CmuxNextApp
import Darwin
import Testing

/// The instant-create bench (`debug.new_tab {action: bench_create}`, instant-new-surfaces-bench.py) times a key's
/// main-thread turn. Its request runs on the control connection's task, at utility QoS (`ControlConnection`'s
/// queue). Sent from that task's main-actor job, the key's turn took the job's utility QoS: on cmux17 (2026-10-29,
/// Time Profiler) macOS ran the main thread on an efficiency core in most runs, and Ctrl-` took about 11 ms instead
/// of 3 ms, every span alike, so the bench reported a budget breach that a person's key (an NSEvent, handled at the
/// main thread's own QoS) does not have. The key's turn never runs at the request's QoS.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct InstantCreateBenchKeyTurnTests {
    @Test func theKeysTurnDoesNotRunAtTheRequestsUtilityQoS() async {
        // The test drives the main thread above utility (user-initiated), so a turn in the request's job is told
        // apart from one in a main run-loop turn.
        let seen = await Task(priority: .high) { @MainActor () -> Seen in
            let seen = Seen(test: qos_class_self().rawValue)
            // The request: a utility task, as the control connection's. Never awaited: an await raises its priority.
            Task(priority: .utility) { @MainActor in
                let turn = await DebugInstantCreateBench.keyTurn(.immediate) { seen.inTurn = qos_class_self().rawValue }
                seen.reported = turn.qos
            }
            for _ in 0..<40 where seen.reported == nil { await drainMainTurns(rounds: 1) }
            return seen
        }.value
        #expect(seen.test != QOS_CLASS_UTILITY.rawValue, "set-up: the test's own turn runs above utility")
        let inTurn = DebugInstantCreateBench.qosName(seen.inTurn ?? 0)
        #expect(seen.inTurn != nil, "the key's turn never ran")
        #expect(seen.inTurn != QOS_CLASS_UTILITY.rawValue,
                "the key's turn ran at \(inTurn), the request task's QoS: the main thread may run it on an efficiency core")
        #expect(seen.reported == seen.inTurn, "key_qos names the QoS the turn ran at")
    }
}

@MainActor
private final class Seen {
    let test: UInt32
    var inTurn: UInt32?
    var reported: UInt32?

    init(test: UInt32) {
        self.test = test
    }
}
