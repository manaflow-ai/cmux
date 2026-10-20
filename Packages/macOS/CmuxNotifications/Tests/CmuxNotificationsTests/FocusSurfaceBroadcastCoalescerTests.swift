import Testing
@testable import CmuxNotifications

@MainActor
@Suite("Focus surface broadcast coalescer")
struct FocusSurfaceBroadcastCoalescerTests {
    private struct TestPayload: Equatable, Sendable {
        let transaction: Int
        let value: Int
    }

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
        var delivered: [TestPayload] = []
        var boundExceeded: [TestPayload] = []
        var tripped: [TestPayload] = []
        let relay = CoalescerRelay<TestPayload>()
        let reentryTarget = TestPayload(transaction: 1, value: 8843)
        var reentryBudget = 1_000

        let coalescer = FocusSurfaceBroadcastCoalescer<TestPayload>(
            maxCoalescedDeliveries: 2,
            maxConsecutiveBoundedFlushes: 4,
            maxCircuitBreakerRecoveryDeliveries: 2,
            belongsToSameCircuit: { $0.transaction == $1.transaction },
            schedule: { scheduler.append($0) },
            onDrainBoundExceeded: { boundExceeded.append($0) },
            onCircuitBreakerTripped: { tripped.append($0) },
            deliver: { payload in
                delivered.append(payload)
                if reentryBudget > 0 {
                    reentryBudget -= 1
                    relay.emit(reentryTarget)
                }
            }
        )
        relay.coalescer = coalescer

        coalescer.emit(TestPayload(transaction: 1, value: 0))

        var turns = 0
        while scheduler.count > 0 && turns < 12 {
            turns += 1
            scheduler.runAll()
        }

        #expect(scheduler.count == 0)
        #expect(turns == 6)
        #expect(delivered.count == 10)
        #expect(delivered.last == reentryTarget)
        #expect(boundExceeded == Array(repeating: reentryTarget, count: 4))
        #expect(tripped == [reentryTarget])
        #expect(reentryBudget > 0)
    }

    @Test("circuit-breaker recovery can publish a finite final payload")
    func circuitBreakerRecoveryPublishesFiniteFinalPayload() {
        let scheduler = ManualScheduler()
        var delivered: [TestPayload] = []
        var boundExceeded: [TestPayload] = []
        var tripped: [TestPayload] = []
        let relay = CoalescerRelay<TestPayload>()

        let first = TestPayload(transaction: 1, value: 1)
        let second = TestPayload(transaction: 1, value: 2)
        let final = TestPayload(transaction: 1, value: 3)
        let external = TestPayload(transaction: 2, value: 4)

        let coalescer = FocusSurfaceBroadcastCoalescer<TestPayload>(
            maxCoalescedDeliveries: 1,
            maxConsecutiveBoundedFlushes: 1,
            maxCircuitBreakerRecoveryDeliveries: 2,
            belongsToSameCircuit: { $0.transaction == $1.transaction },
            schedule: { scheduler.append($0) },
            onDrainBoundExceeded: { boundExceeded.append($0) },
            onCircuitBreakerTripped: { tripped.append($0) },
            deliver: { payload in
                delivered.append(payload)
                if payload == first {
                    relay.emit(second)
                } else if payload == second {
                    relay.emit(final)
                }
            }
        )
        relay.coalescer = coalescer

        coalescer.emit(first)
        while scheduler.count > 0 {
            scheduler.runAll()
        }

        #expect(delivered == [first, second, final])
        #expect(boundExceeded == [second])
        #expect(tripped == [second])
        #expect(scheduler.count == 0)

        coalescer.emit(external)
        #expect(scheduler.count == 1)
        scheduler.runAll()

        #expect(delivered == [first, second, final, external])
        #expect(scheduler.count == 0)
    }

    @Test("same-circuit deferred feedback is bounded across scheduler turns")
    func sameCircuitDeferredFeedbackTripsAcrossTurns() {
        let scheduler = ManualScheduler()
        var delivered: [TestPayload] = []
        var tripped: [TestPayload] = []
        let relay = CoalescerRelay<TestPayload>()
        let initial = TestPayload(transaction: 1, value: 0)
        let feedback = TestPayload(transaction: 1, value: 7)
        var deferredFeedbackBudget = 1_000

        let coalescer = FocusSurfaceBroadcastCoalescer<TestPayload>(
            maxCoalescedDeliveries: 8,
            maxConsecutiveBoundedFlushes: 4,
            maxConsecutiveCircuitDeliveries: 3,
            maxCircuitBreakerRecoveryDeliveries: 2,
            belongsToSameCircuit: { $0.transaction == $1.transaction },
            schedule: { scheduler.append($0) },
            onCircuitBreakerTripped: { tripped.append($0) },
            deliver: { payload in
                delivered.append(payload)
                guard deferredFeedbackBudget > 0 else { return }
                deferredFeedbackBudget -= 1
                scheduler.append {
                    relay.emit(feedback)
                }
            }
        )
        relay.coalescer = coalescer

        coalescer.emit(initial)

        var turns = 0
        while scheduler.count > 0 && turns < 20 {
            turns += 1
            scheduler.runAll()
        }

        #expect(scheduler.count == 0)
        #expect(turns == 11)
        #expect(delivered == [initial, feedback, feedback, feedback, feedback])
        #expect(tripped == [feedback])
        #expect(deferredFeedbackBudget > 0)
    }
}
