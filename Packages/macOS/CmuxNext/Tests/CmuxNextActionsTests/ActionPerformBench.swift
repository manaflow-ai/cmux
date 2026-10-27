import CmuxNextActions
// A base older than the writer has no CmuxNextTestSupport: action-perform-ab.py copies this file there.
#if canImport(CmuxNextTestSupport)
import CmuxNextTestSupport
#endif
import Foundation
import Testing

/// What one `ActionRegistry.perform` of a no-op action costs, the `action-perform` perf-hot path
/// (scripts/cmux-next/perf-hot-benches.json, budget < 1 us), in the registry Release builds: no turn
/// observer. It uses only API the push base has, so the same file runs at the base SHA and at the head
/// SHA: scripts/cmux-next/action-perform-ab.py copies it into a base worktree, runs the two SHAs
/// alternately on one host and prints what the head adds per perform with its 95% interval. Each
/// round prints one `action-perform-bench round=<n> ns=<ns per perform>` line for it, and with
/// CMUX_PERF_RESULT_DIR the rounds are one result-v1 series (lab story swift-action-perform). A
/// measurement, not a gate.
///
/// ```
/// CMUX_ACTION_PERFORM_BENCH=1 swift test -c release --filter ActionPerformBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_ACTION_PERFORM_BENCH"] == "1"))
struct ActionPerformBench {
    private static let rounds = 40
    private static let performsPerRound = 100_000

    @Test func performsANoopAction() throws {
        let registry = ActionRegistry(catalog: [], runTiming: NoActionRunTiming())
        registry.register(Action(id: "bench.noop", title: "Noop") {})
        _ = Self.round(registry)  // warm
        var rounds: [Double] = []
        for index in 0..<Self.rounds {
            let nanos = Self.round(registry)
            rounds.append(nanos)
            print(String(format: "action-perform-bench round=%d ns=%.3f", index, nanos))
        }
        #if canImport(CmuxNextTestSupport)
        try PerfResultWriter()?.record("swift.action_perform.perform_ns", unit: .ns, samples: rounds)
        #endif
    }

    /// Nanoseconds per perform of `bench.noop` over one round (the budget monitor's uptime clock).
    private static func round(_ registry: ActionRegistry) -> Double {
        var ran = 0
        let start = ActionBudgetMonitor.now()
        for _ in 0..<performsPerRound {
            if registry.perform("bench.noop") { ran &+= 1 }
        }
        let nanos = ActionBudgetMonitor.now() - start
        precondition(ran == performsPerRound)
        return Double(nanos) / Double(performsPerRound)
    }
}
