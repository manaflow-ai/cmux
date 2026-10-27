#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextActions
import CmuxNextControl
import CmuxNextOracle
import CmuxNextTestSupport
import Foundation
import Testing

/// What the DEV and bench builds' turn recorder adds to `ActionRegistry.perform` while disarmed (the
/// `action-perform` perf-hot path, budget < 1 us): the App's real observer, ``OracleActionTurns``,
/// with its existential call, the id and origin strings and the recorder's armed check, against the
/// same registry with no observer. The two arms alternate in rounds in one process, so drift hits
/// both; the line gives the mean difference with its 95% interval over the rounds. What Release adds
/// over the push base is ActionPerformBench's A/B (scripts/cmux-next/action-perform-ab.py). A
/// measurement, not a gate: run it with bench hooks in a Release build on each macOS major. With
/// CMUX_PERF_RESULT_DIR it also writes the rounds as result-v1 (lab story swift-oracle-turns).
///
/// ```
/// CMUX_ORACLE_TURNS_BENCH=1 swift test -c release -Xswiftc -DCMUX_BENCH_HOOKS --filter OracleActionTurnsBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_ORACLE_TURNS_BENCH"] == "1"))
struct OracleActionTurnsBench {
    private static let rounds = 40
    private static let performsPerRound = 100_000

    private static func registry(_ observer: (any ActionRunObserver)?) -> ActionRegistry {
        let registry = ActionRegistry(catalog: [], runTiming: NoActionRunTiming(), turnObserver: observer)
        registry.register(Action(id: "bench.noop", title: "Noop") {})
        return registry
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

    @Test func theDisarmedRecorderCostsUnderAMicrosecondPerPerform() throws {
        let turns = OracleActionTurns()
        let bare = Self.registry(nil)
        let observed = Self.registry(turns)
        _ = Self.round(bare)  // warm
        _ = Self.round(observed)

        var differences: [Double] = []
        var bareMeans: [Double] = []
        for index in 0..<Self.rounds {
            // Alternate which arm goes first, so neither always runs on a warmer cache.
            let (first, second) = index.isMultiple(of: 2) ? (bare, observed) : (observed, bare)
            let a = Self.round(first)
            let b = Self.round(second)
            let (without, with) = index.isMultiple(of: 2) ? (a, b) : (b, a)
            bareMeans.append(without)
            differences.append(with - without)
        }
        let mean = differences.reduce(0, +) / Double(differences.count)
        let variance = differences.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(differences.count - 1)
        let halfWidth = 1.96 * (variance / Double(differences.count)).squareRoot()
        let base = bareMeans.reduce(0, +) / Double(bareMeans.count)
        print(String(format: "oracle-turns bench: macOS %@, %d rounds x %d performs: no observer %.1f ns/perform; "
                     + "disarmed OracleActionTurns adds %.1f ns (95%% CI %.1f to %.1f)",
                     ProcessInfo.processInfo.operatingSystemVersionString, Self.rounds, Self.performsPerRound, base,
                     mean, mean - halfWidth, mean + halfWidth))
        if let results = try PerfResultWriter() {
            try results.record("swift.oracle_turns.no_observer_ns", unit: .ns, samples: bareMeans)
            try results.record("swift.oracle_turns.disarmed_added_ns", unit: .ns, samples: differences)
        }
        #expect(turns.recorder.ring.count == 0)
        #expect(mean + halfWidth < 1_000)
    }
}
#endif
