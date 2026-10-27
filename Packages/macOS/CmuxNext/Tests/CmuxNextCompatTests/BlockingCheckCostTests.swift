#if CMUX_BLOCKING_CHECKS && !DEBUG
@testable import CmuxNextCompat
import Foundation
import Testing

/// The clean path of the configuration a Nightly will use (Release + `-DCMUX_BLOCKING_CHECKS`;
/// `reload.sh --config bench-checks` uses it today): a checked call that
/// does not block the main thread costs under 50 ns at p99 (lead budget 2026-10-24). Compiled only in that
/// configuration (scripts/measure/blocking-checks.sh runs it on the fleet), never in Debug or CI.
///
/// Off the main thread a call where blocking is allowed is classified first (p02-threads 005): on a named
/// serial queue it reads the thread's flags and the queue label (one prefix compare); on a lane or a named
/// thread (after its first check) it reads the flags only. A pool thread is a violation, so its cost is not the
/// clean path's.
///
/// One call is far shorter than a clock read, so the p99 is over batches: each batch times ``batchCalls`` calls,
/// and the p99 is of the batches' cost per call.
@Suite(.serialized)
struct BlockingCheckCostTests {
    nonisolated private static let batches = 2_000
    nonisolated private static let batchCalls = 5_000
    private static let budgetNanos = 50.0

    @Test func aCheckOnANamedQueueCostsUnderTheBudget() async {
        let cost = await Self.onNamedQueue { Self.costPerCall { assertBlockingAllowed(.fileIO) } }
        Self.report("off the main thread (named queue)", cost)
        #expect(cost.p99 < Self.budgetNanos)
    }

    /// `blockingCall` off the main thread is the same classification and reads no clock.
    @Test func aBlockingCallOnANamedQueueCostsUnderTheBudget() async {
        let cost = await Self.onNamedQueue { Self.costPerCall { blockingCall(.fileIO) {} } }
        Self.report("blockingCall off the main thread (named queue)", cost)
        #expect(cost.p99 < Self.budgetNanos)
    }

    /// On a lane slot the thread's mark decides without the label.
    @Test func aBlockingCallOnALaneCostsUnderTheBudget() async {
        let cost = await Self.onNamedQueue { BlockingContext.runAsLane { Self.costPerCall { blockingCall(.fileIO) {} } } }
        Self.report("blockingCall on a lane", cost)
        #expect(cost.p99 < Self.budgetNanos)
    }

    /// A named `Thread` runs no queue, so it reads the default root queue's label; its first check reads its
    /// name and marks it dedicated, so every later check is the flags read alone.
    @Test func aBlockingCallOnANamedThreadCostsUnderTheBudget() async {
        let cost = await Self.onNamedThread { Self.costPerCall { blockingCall(.fileIO) {} } }
        Self.report("blockingCall on a named thread", cost)
        #expect(cost.p99 < Self.budgetNanos)
    }

    @Test func aCheckOnANamedThreadCostsUnderTheBudget() async {
        let cost = await Self.onNamedThread { Self.costPerCall { assertBlockingAllowed(.fileIO) } }
        Self.report("off the main thread (named thread)", cost)
        #expect(cost.p99 < Self.budgetNanos)
    }

    @MainActor @Test func aRepeatOfAKnownSiteOnTheMainThreadCostsUnderTheBudget() async {
        let table = BlockingViolationTable(mode: .record)
        let cost = BlockingViolationTable.$scoped.withValue(table) { Self.costPerCall { assertBlockingAllowed(.fileIO) } }
        await table.flush()
        Self.report("a known site on the main thread", cost)
        #expect(cost.p99 < Self.budgetNanos)
        #expect(BlockingDetector(table: table).sites.count == 1)
    }

    /// The cost per call of one batch: its median and p99 over ``batches``.
    nonisolated struct Cost: Sendable {
        var median: Double
        var p99: Double
    }

    nonisolated private static func report(_ path: String, _ cost: Cost) {
        print("blocking-check cost: \(path) p50 \(String(format: "%.2f", cost.median)) ns, "
            + "p99 \(String(format: "%.2f", cost.p99)) ns per call")
    }

    /// Runs `body` on a named serial queue (a dedicated context: not the cooperative pool or a GCD root queue).
    nonisolated private static func onNamedQueue(_ body: @escaping @Sendable () -> Cost) async -> Cost {
        let queue = DispatchQueue(label: "com.cmuxterm.tests.blocking-check-cost")
        return await withCheckedContinuation { (done: CheckedContinuation<Cost, Never>) in
            queue.async { done.resume(returning: body()) }
        }
    }

    /// Runs `body` on a named `Thread` that runs no queue.
    nonisolated private static func onNamedThread(_ body: @escaping @Sendable () -> Cost) async -> Cost {
        await withCheckedContinuation { (done: CheckedContinuation<Cost, Never>) in
            let thread = Thread {
                pthread_setname_np("com.cmuxterm.tests.blocking-check-cost-thread")
                done.resume(returning: body())
            }
            thread.start()
        }
    }

    /// Times ``batches`` batches of ``batchCalls`` calls of `call` and returns the cost per call.
    @inline(__always)
    nonisolated private static func costPerCall(_ call: () -> Void) -> Cost {
        var perCall: [Double] = []
        perCall.reserveCapacity(batches)
        for _ in 0..<batches {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<batchCalls { call() }
            perCall.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(batchCalls))
        }
        perCall.sort()
        return Cost(median: perCall[perCall.count / 2], p99: perCall[min(perCall.count - 1, perCall.count * 99 / 100)])
    }
}
#endif
