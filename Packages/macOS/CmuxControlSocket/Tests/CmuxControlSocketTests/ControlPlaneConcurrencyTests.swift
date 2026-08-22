import CmuxControlSocket
import Foundation
import os
import Testing

private actor PoolProbe {
    private var active = 0
    private var peak = 0
    private var completed: [Int] = []

    func started() {
        active += 1
        peak = max(peak, active)
    }

    func finished(_ id: Int) {
        active -= 1
        completed.append(id)
    }

    func snapshot() -> (active: Int, peak: Int, completed: [Int]) {
        (active, peak, completed)
    }
}

private actor PoolGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func openNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: UInt64(0))

    var now: UInt64 {
        value.withLock { $0 }
    }

    func advance(by nanoseconds: UInt64) {
        value.withLock { $0 += nanoseconds }
    }
}

@Suite("Control-plane concurrency primitives")
struct ControlPlaneConcurrencyTests {
    @Test func workerPoolBoundsActiveJobsAndRejectsOverflow() async {
        let pool = ControlClientWorkerPool(
            maximumConcurrentJobs: 2,
            maximumPendingJobs: 1
        )
        let probe = PoolProbe()
        let gate = PoolGate()

        let first = await pool.submit {
            await probe.started()
            await gate.wait()
            await probe.finished(1)
        }
        let second = await pool.submit {
            await probe.started()
            await gate.wait()
            await probe.finished(2)
        }
        let third = await pool.submit {
            await probe.started()
            await gate.wait()
            await probe.finished(3)
        }
        let fourth = await pool.submit {
            await probe.started()
            await gate.wait()
            await probe.finished(4)
        }

        #expect(first == .started)
        #expect(second == .started)
        #expect(third == .queued)
        #expect(fourth == .rejected)

        for _ in 0..<100 where await pool.metrics().activeJobs < 2 {
            await Task.yield()
        }
        #expect(await pool.metrics().activeJobs == 2)
        #expect(await pool.metrics().peakActiveJobs == 2)

        await gate.openNext()
        await gate.openNext()
        for _ in 0..<100 where await pool.metrics().activeJobs != 1 {
            await Task.yield()
        }
        await gate.openNext()

        for _ in 0..<100 where await pool.metrics().activeJobs != 0 {
            await Task.yield()
        }
        let result = await probe.snapshot()
        #expect(result.peak == 2)
        #expect(result.completed.count == 3)
        #expect(result.completed.prefix(2).allSatisfy { $0 == 1 || $0 == 2 })
        #expect(result.completed.last == 3)
    }

    @Test func pollingLimiterAllowsBurstThenAppliesPerClientBackpressure() async {
        let clock = TestMonotonicClock()
        let limiter = ControlClientRateLimiter(
            configuration: .init(
                burst: 2,
                refillIntervalNanoseconds: 100
            ),
            now: { clock.now }
        )

        #expect(await limiter.admit(method: "system.top") == .allowed)
        #expect(await limiter.admit(method: "system.top") == .allowed)
        guard case .limited(let retryAfter) = await limiter.admit(method: "system.top") else {
            Issue.record("third polling request should be rate limited")
            return
        }
        #expect(retryAfter > 0)
        #expect(await limiter.admit(method: "system.ping") == .allowed)

        clock.advance(by: 100)
        #expect(await limiter.admit(method: "system.top") == .allowed)
    }

    @Test func readSnapshotPublishesAtomicallyAndKeysByMethodAndParams() {
        let store = ControlReadSnapshotStore()
        let initial = ControlCallResult.ok(.object(["generation": .int(1)]))
        store.publish(
            ControlReadSnapshot(
                generation: 1,
                responses: [
                    ControlReadSnapshot.key(method: "workspace.list", params: [:]): initial,
                ]
            )
        )

        #expect(
            store.response(method: "workspace.list", params: [:]) == initial
        )
        #expect(store.response(method: "workspace.list", params: ["all": .bool(true)]) == nil)

        let replacement = ControlCallResult.ok(.object(["generation": .int(2)]))
        store.publishResponse(
            method: "workspace.list",
            params: [:],
            result: replacement
        )
        #expect(store.response(method: "workspace.list", params: [:]) == replacement)
        #expect(store.read().generation == 2)
    }
}
