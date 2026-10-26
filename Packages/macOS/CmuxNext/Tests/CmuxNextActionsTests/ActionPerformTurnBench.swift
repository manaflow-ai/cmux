import CmuxNextActions
import Foundation
import Testing

/// An observer that hears every turn and records nothing: the DEV recorder disarmed.
@MainActor
private final class DisarmedObserver: ActionRunObserver {
    private(set) var turns = 0
    func performTurnEnded(_ turn: ActionTurn) { turns &+= 1 }
}

/// The cost the oracle's perform-turn hook (p15-oracle-032) adds to `ActionRegistry.perform`, the
/// `action-perform` perf-hot path (scripts/cmux-next/perf-hot-benches.json, budget < 1 us): Release
/// (no observer, one nil check) against DEV with the recorder disarmed (the depth count and one call).
/// Same process, same host: the two arms alternate in rounds, so drift hits both, and the line gives
/// the mean difference with its 95% interval over the rounds. A measurement, not a gate: run it in a
/// Release build on each macOS major and quote the line.
///
/// ```
/// CMUX_ACTION_PERFORM_BENCH=1 swift test -c release --filter ActionPerformTurnBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_ACTION_PERFORM_BENCH"] == "1"))
struct ActionPerformTurnBench {
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

    @Test func theHookCostsUnderAMicrosecondPerPerform() {
        let observer = DisarmedObserver()
        let release = Self.registry(nil)
        let dev = Self.registry(observer)
        _ = Self.round(release)  // warm
        _ = Self.round(dev)

        var differences: [Double] = []
        var releaseMeans: [Double] = []
        for index in 0..<Self.rounds {
            // Alternate which arm goes first, so neither always runs on a warmer cache.
            let (first, second) = index.isMultiple(of: 2) ? (release, dev) : (dev, release)
            let a = Self.round(first)
            let b = Self.round(second)
            let (bare, hooked) = index.isMultiple(of: 2) ? (a, b) : (b, a)
            releaseMeans.append(bare)
            differences.append(hooked - bare)
        }
        let mean = differences.reduce(0, +) / Double(differences.count)
        let variance = differences.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(differences.count - 1)
        let halfWidth = 1.96 * (variance / Double(differences.count)).squareRoot()
        let base = releaseMeans.reduce(0, +) / Double(releaseMeans.count)
        print(String(format: "action-perform bench: macOS %@, %d rounds x %d performs: no observer %.1f ns/perform; "
                     + "disarmed observer adds %.1f ns (95%% CI %.1f to %.1f)",
                     ProcessInfo.processInfo.operatingSystemVersionString, Self.rounds, Self.performsPerRound, base,
                     mean, mean - halfWidth, mean + halfWidth))
        #expect(observer.turns == Self.performsPerRound * (Self.rounds + 1))
        #expect(mean + halfWidth < 1_000)
    }
}
