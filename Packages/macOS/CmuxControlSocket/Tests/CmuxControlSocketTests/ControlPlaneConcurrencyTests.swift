import CmuxControlSocket
import Foundation
import os
import Testing

private actor PoolProbe {
    private var active = 0
    private var peak = 0
    private var startedCount = 0
    private var completed: [Int] = []

    func started() {
        active += 1
        startedCount += 1
        peak = max(peak, active)
    }

    func finished(_ id: Int) {
        active -= 1
        completed.append(id)
    }

    func snapshot() -> (active: Int, peak: Int, completed: [Int]) {
        (active, peak, completed)
    }

    func hasStarted(_ count: Int) -> Bool {
        startedCount >= count
    }
}

private actor PoolGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func openNext() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            permits += 1
        }
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

        for _ in 0..<10_000 {
            if await probe.hasStarted(2) { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await probe.hasStarted(2))
        #expect(await pool.metrics().activeJobs == 2)
        #expect(await pool.metrics().peakActiveJobs == 2)

        await gate.openNext()
        await gate.openNext()
        for _ in 0..<10_000 {
            if await probe.snapshot().completed.count >= 1 { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<10_000 {
            if await probe.hasStarted(3) { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        await gate.openNext()

        for _ in 0..<10_000 {
            if await probe.snapshot().completed.count == 3 { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        let result = await probe.snapshot()
        #expect(result.peak == 2)
        #expect(result.completed.count == 3)
        #expect(Set(result.completed) == Set([1, 2, 3]))
    }

    @Test func workerPoolDropsPendingJobsThatOutlivedTheirClientInsteadOfRunningThemLate() async {
        let clock = TestMonotonicClock()
        let pool = ControlClientWorkerPool(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 4,
            maximumPendingAgeNanoseconds: 15_000_000_000,
            now: { clock.now }
        )
        let probe = PoolProbe()
        let gate = PoolGate()
        let drops = OSAllocatedUnfairLock(initialState: [ControlClientWorkerPool.DropReason]())

        // A stalled first job holds the only slot, as a main-actor hop parked
        // behind a modal run loop did in #13369.
        let first = await pool.submit {
            await probe.started()
            await gate.wait()
            await probe.finished(1)
        }
        let second = await pool.submit {
            await probe.started()
            await probe.finished(2)
        } onDrop: { reason in
            drops.withLock { $0.append(reason) }
        }
        #expect(first == .started)
        #expect(second == .queued)

        // The client of the queued job gives up (15 s CLI timeout) long before
        // the slot frees.
        clock.advance(by: 16_000_000_000)
        let third = await pool.submit {
            await probe.started()
            await probe.finished(3)
        }
        #expect(third == .queued)

        await gate.openNext()
        for _ in 0..<10_000 {
            if await probe.snapshot().completed.contains(3) { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }

        let result = await probe.snapshot()
        #expect(result.completed == [1, 3])
        #expect(drops.withLock { $0 } == [.pendingExpired])
        let metrics = await pool.metrics()
        #expect(metrics.expiredJobs == 1)
        #expect(metrics.pendingJobs == 0)
        #expect(metrics.rejectedJobs == 0)
    }

    @Test func workerPoolTellsDroppedJobsWhyTheyWereDropped() async {
        let pool = ControlClientWorkerPool(maximumConcurrentJobs: 1, maximumPendingJobs: 0)
        let gate = PoolGate()
        let drops = OSAllocatedUnfairLock(initialState: [ControlClientWorkerPool.DropReason]())

        _ = await pool.submit { await gate.wait() }
        let overflow = await pool.submit {} onDrop: { reason in
            drops.withLock { $0.append(reason) }
        }
        #expect(overflow == .rejected)

        await pool.stop()
        let afterStop = await pool.submit {} onDrop: { reason in
            drops.withLock { $0.append(reason) }
        }
        #expect(afterStop == .rejected)
        #expect(drops.withLock { $0 } == [.pendingQueueFull, .stopped])
        await gate.openNext()
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

    @Test func pollingLimiterAdmitsTmuxCompatReadFanoutBeforeRefill() async {
        let clock = TestMonotonicClock()
        let limiter = ControlClientRateLimiter(now: { clock.now })
        let tmuxFormatContextMethods = [
            "surface.current",
            "pane.list",
            "surface.list",
            "workspace.list",
            "window.list",
            "workspace.list",
            "workspace.list",
            "workspace.current",
            "workspace.list",
        ]

        for method in tmuxFormatContextMethods {
            #expect(await limiter.admit(method: method) == .allowed)
        }
        guard case .limited(let retryAfter) = await limiter.admit(method: "surface.list") else {
            Issue.record("the complete tmux compatibility read fan-out should fit in one burst")
            return
        }
        #expect(retryAfter > 0)

        clock.advance(by: 100_000_000)
        #expect(await limiter.admit(method: "surface.list") == .allowed)
    }

    @Test func readSnapshotPublishesAtomicallyAndKeysByMethodAndParams() {
        let store = ControlReadSnapshotStore()
        let initial = ControlCallResult.ok(.object(["generation": .int(1)]))
        store.publish(
            ControlReadSnapshot(
                generation: 1,
                responses: [
                    ControlReadSnapshot.key(method: "workspace.list", params: [:]): initial,
                ],
                publishedAtUptimeNanoseconds: 100
            )
        )

        #expect(
            store.response(method: "workspace.list", params: [:]) == initial
        )
        let differentParams: [String: JSONValue] = ["all": .bool(true)]
        #expect(store.response(method: "workspace.list", params: differentParams) == nil)
        #expect(
            store.response(
                method: "workspace.list",
                params: [:],
                maximumAgeNanoseconds: 100,
                nowUptimeNanoseconds: 200
            ) == initial
        )
        #expect(
            store.response(
                method: "workspace.list",
                params: [:],
                maximumAgeNanoseconds: 100,
                nowUptimeNanoseconds: 201
            ) == nil
        )

        let replacement = ControlCallResult.ok(.object(["generation": .int(2)]))
        store.publishResponse(
            method: "workspace.list",
            params: [:],
            result: replacement
        )
        #expect(store.response(method: "workspace.list", params: [:]) == replacement)
        #expect(store.read().generation == 2)
    }

    @Test func readAndPollingPoliciesShareOneClassification() {
        #expect(
            ControlCommandExecutionPolicy.servesFromPublishedReadSnapshot(
                method: "workspace.list"
            )
        )
        #expect(
            ControlCommandExecutionPolicy.servesFromPublishedReadSnapshot(
                method: "surface.read_text"
            )
        )
        #expect(
            ControlCommandExecutionPolicy.pollingMethods.contains("system.top")
        )
        #expect(
            ControlCommandExecutionPolicy.pollingMethods.contains("surface.read_selection")
        )
        #expect(
            !ControlCommandExecutionPolicy.pollingMethods.contains("workspace.create")
        )
    }

    @Test func snapshotReadersRemainSafeDuringConcurrentPublications() async {
        let store = ControlReadSnapshotStore()
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<2 {
                group.addTask {
                    for generation in 0..<200 {
                        store.publish(
                            ControlReadSnapshot(
                                generation: UInt64(writer * 1_000 + generation),
                                responses: [:]
                            )
                        )
                    }
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<500 {
                        _ = store.read().generation
                    }
                }
            }
        }
        #expect(store.read().responses.isEmpty)
    }
}
