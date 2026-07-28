import Testing
@testable import CmuxNotifications

@MainActor
@Suite("Focus surface broadcast coalescer")
struct FocusSurfaceBroadcastCoalescerTests {
    @MainActor
    private final class ManualScheduler {
        private(set) var pending: [@MainActor @Sendable () -> Void] = []

        func append(_ work: @escaping @MainActor @Sendable () -> Void) {
            pending.append(work)
        }

        var count: Int { pending.count }

        func runAll() {
            let work = pending
            pending.removeAll()
            for unit in work { unit() }
        }
    }

    /// Safe because the relay is main-actor isolated and every captured test
    /// delivery closure is also `@MainActor`.
    @MainActor
    private final class CoalescerRelay<Payload: Sendable>: @unchecked Sendable {
        var coalescer: FocusSurfaceBroadcastCoalescer<Payload>?

        func emit(_ payload: Payload) {
            coalescer?.emit(payload)
        }
    }

    @Test("emits asynchronously and coalesces to the latest payload")
    func emitDefersAndCoalesces() {
        let scheduler = ManualScheduler()
        var delivered: [Int] = []
        let coalescer = FocusSurfaceBroadcastCoalescer<Int>(
            schedule: { scheduler.append($0) },
            deliver: { delivered.append($0) }
        )

        coalescer.emit(1)
        coalescer.emit(2)
        coalescer.emit(3)

        #expect(delivered.isEmpty)
        #expect(scheduler.count == 1)

        scheduler.runAll()
        #expect(delivered == [3])
    }

    @Test("finite re-entrant cycles drain without dropping the final payload")
    func finiteReentrantCycleDrains() {
        let scheduler = ManualScheduler()
        var delivered: [Int] = []
        let relay = CoalescerRelay<Int>()
        var reEmitsRemaining = 2

        let coalescer = FocusSurfaceBroadcastCoalescer<Int>(
            maxCoalescedDeliveries: 8,
            schedule: { scheduler.append($0) },
            deliver: { payload in
                delivered.append(payload)
                if reEmitsRemaining > 0 {
                    reEmitsRemaining -= 1
                    relay.emit(7)
                }
            }
        )
        relay.coalescer = coalescer

        coalescer.emit(0)
        scheduler.runAll()

        #expect(delivered == [0, 7, 7])
        #expect(scheduler.count == 0)
    }

    @Test("non-converging re-entrant cycles trip the circuit breaker")
    func nonConvergingReentrantCycleTripsCircuitBreaker() {
        let scheduler = ManualScheduler()
        var delivered: [Int] = []
        var boundExceeded: [Int] = []
        var tripped: [Int] = []
        let relay = CoalescerRelay<Int>()
        var reentryBudget = 1_000

        let coalescer = FocusSurfaceBroadcastCoalescer<Int>(
            maxCoalescedDeliveries: 2,
            maxConsecutiveBoundedFlushes: 4,
            schedule: { scheduler.append($0) },
            onDrainBoundExceeded: { boundExceeded.append($0) },
            onCircuitBreakerTripped: { tripped.append($0) },
            deliver: { payload in
                delivered.append(payload)
                if reentryBudget > 0 {
                    reentryBudget -= 1
                    relay.emit(8843)
                }
            }
        )
        relay.coalescer = coalescer

        coalescer.emit(0)

        var turns = 0
        while scheduler.count > 0 && turns < 12 {
            turns += 1
            scheduler.runAll()
        }

        #expect(scheduler.count == 0)
        #expect(turns == 4)
        // The breaker preserves the latest requested focus once before dropping
        // the re-entrant continuation that would otherwise keep rescheduling.
        #expect(delivered.count == 9)
        #expect(delivered.last == 8843)
        #expect(boundExceeded == [8843, 8843, 8843, 8843])
        #expect(tripped == [8843])
        #expect(reentryBudget > 0)
    }
}
