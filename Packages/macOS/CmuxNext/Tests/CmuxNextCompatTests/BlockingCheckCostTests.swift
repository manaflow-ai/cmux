#if CMUX_BLOCKING_CHECKS && !DEBUG
@testable import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The clean path of the configuration a Nightly will use (Release + `-DCMUX_BLOCKING_CHECKS`; bench builds use it today): a checked call that
/// does not block the main thread costs under 50 ns (lead budget 2026-10-24). Compiled only in that
/// configuration (scripts/measure/blocking-checks.sh runs it on the fleet), never in Debug or CI.
///
/// Off the main thread a call where blocking is allowed is classified first (p02-threads 005): on a named
/// serial queue it reads the thread's flags and the queue label (one prefix compare, one suffix compare); on a
/// lane it reads the flags only. A pool thread is a violation, so its cost is not the clean path's.
@Suite(.serialized)
struct BlockingCheckCostTests {
    /// The calls per timed run, and the runs (the fastest one counts: the others carry scheduler noise).
    nonisolated private static let calls = 10_000_000
    nonisolated private static let runs = 5
    private static let budgetNanos = 50.0

    @Test func aCheckOnANamedQueueCostsUnderTheBudget() async {
        let nanos = await Self.onNamedQueue { Self.fastestNanosPerCall() }
        print("blocking-check cost: off the main thread (named queue) \(String(format: "%.2f", nanos)) ns per call")
        #expect(nanos < Self.budgetNanos)
    }

    /// `blockingCall` off the main thread is the same classification and reads no clock.
    @Test func aBlockingCallOnANamedQueueCostsUnderTheBudget() async {
        let nanos = await Self.onNamedQueue { Self.fastestNanosPerBlockingCall() }
        print("blocking-check cost: blockingCall off the main thread (named queue) \(String(format: "%.2f", nanos)) ns per call")
        #expect(nanos < Self.budgetNanos)
    }

    /// On a lane slot the thread's mark decides without the label.
    @Test func aBlockingCallOnALaneCostsUnderTheBudget() async {
        let nanos = await Self.onNamedQueue { BlockingContext.run(as: .lane) { Self.fastestNanosPerBlockingCall() } }
        print("blocking-check cost: blockingCall on a lane \(String(format: "%.2f", nanos)) ns per call")
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

    /// Runs `body` on a named serial queue (a dedicated context: not the cooperative pool or a GCD root queue).
    nonisolated private static func onNamedQueue(_ body: @escaping @Sendable () -> Double) async -> Double {
        let queue = DispatchQueue(label: "com.cmuxterm.tests.blocking-check-cost")
        return await withCheckedContinuation { (done: CheckedContinuation<Double, Never>) in
            queue.async { done.resume(returning: body()) }
        }
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

    nonisolated private static func fastestNanosPerBlockingCall() -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<calls { blockingCall(.fileIO) {} }
            best = min(best, Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(calls))
        }
        return best
    }
}
#endif
