#if CMUX_BLOCKING_CHECKS && !DEBUG
@testable import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The clean path of the configuration a Nightly will use (Release + `-DCMUX_BLOCKING_CHECKS`; bench builds use it today): a checked call that
/// does not block the main thread costs under 50 ns (lead budget 2026-10-24). Compiled only in that
/// configuration (scripts/measure/blocking-checks.sh runs it on the fleet), never in Debug or CI.
@Suite(.serialized)
struct BlockingCheckCostTests {
    /// The calls per timed run, and the runs (the fastest one counts: the others carry scheduler noise).
    nonisolated private static let calls = 10_000_000
    nonisolated private static let runs = 5
    private static let budgetNanos = 50.0

    @Test func aCheckOffTheMainThreadCostsUnderTheBudget() async {
        let nanos = await Task.detached { Self.fastestNanosPerCall() }.value
        print("blocking-check cost: off the main thread \(String(format: "%.2f", nanos)) ns per call")
        #expect(nanos < Self.budgetNanos)
    }

    @MainActor @Test func aRepeatOfAKnownSiteOnTheMainThreadCostsUnderTheBudget() async {
        let table = BlockingViolationTable(mode: .record)
        let nanos = BlockingViolationTable.$scoped.withValue(table) { Self.fastestNanosPerCall() }
        await table.flush()
        print("blocking-check cost: a known site on the main thread \(String(format: "%.2f", nanos)) ns per call")
        #expect(nanos < Self.budgetNanos)
        #expect(BlockingDetector(table: table).sites.count == 1)
    }

    nonisolated private static func fastestNanosPerCall() -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<calls { assertBlockingAllowed(.fileIO) }
            best = min(best, Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(calls))
        }
        return best
    }
}
#endif
