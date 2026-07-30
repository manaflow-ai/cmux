import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Completes eviction grace windows immediately so the all-paths-closed
/// deadline fires as soon as it is armed.
private struct ImmediateGraceClock: CmxIrohRelayClock {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date { date }
    func sleep(until _: Date) async throws {}
}

/// Holds every grace-window sleep until the test releases it, so path
/// recovery can be observed disarming the eviction deterministically.
private actor HoldingGraceClock: CmxIrohRelayClock {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sleepCount = 0

    nonisolated func now() -> Date { date }

    func sleep(until _: Date) async throws {
        sleepCount += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        let resumable = waiters
        waiters = []
        for waiter in resumable { waiter.resume() }
    }

    func observedSleepCount() -> Int { sleepCount }

    func waitForSleeper() async -> Bool {
        for _ in 0..<400 {
            if sleepCount > 0 { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return sleepCount > 0
    }
}

@Suite
struct CmxIrohClientSessionPoolPathEvictionTests {
    @Test
    func sessionWithNoUsablePathIsEvictedAndAttributedAfterGrace() async throws {
        let fixture = try PoolFixture()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            selectedPath: .privateNetwork
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [.connection(connection)]
        )
        let diagnosticLog = DiagnosticLog()
        let pool = try await fixture.pool(
            endpoint: endpoint,
            generation: 1,
            diagnosticLog: diagnosticLog,
            clock: ImmediateGraceClock()
        )

        let transport = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)
        try await transport.connect()
        #expect(await pool.selectedObservedPath() == .privateNetwork)

        await connection.setObservedSelectedPath(.unavailable)

        let evicted = await pollUntilTrue {
            let pathUnavailable = await pool.selectedObservedPath() == .unavailable
            let closed = await connection.observedCloseCallCount() > 0
            return pathUnavailable && closed
        }
        #expect(evicted)

        let events = await drainedEvents(from: diagnosticLog)
        let closure = events.last { $0.code == .sessionClosed }
        #expect(closure != nil)
        #expect(closure?.diagnosticFailureKind == .noRoute)
        let lifecycleRemoval = events.last { event in
            event.code == .transportSessionLifecycle
                && event.diagnosticSessionLifecycleKind == .allPathsClosed
        }
        #expect(lifecycleRemoval != nil)
    }

    @Test
    func pathRecoveryWithinGraceDisarmsTheEviction() async throws {
        let fixture = try PoolFixture()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            selectedPath: .privateNetwork
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [.connection(connection)]
        )
        let clock = HoldingGraceClock()
        let pool = try await fixture.pool(
            endpoint: endpoint,
            generation: 1,
            clock: clock
        )

        let transport = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)
        try await transport.connect()
        let pathChanges = await pool.selectedPathChanges()
        var pathIterator = pathChanges.makeAsyncIterator()
        _ = await pathIterator.next()

        await connection.setObservedSelectedPath(.unavailable)
        _ = await pathIterator.next()
        #expect(await clock.waitForSleeper())

        // The path recovers while the grace window is still pending; releasing
        // the window afterwards must not evict the healthy session.
        await connection.setObservedSelectedPath(.relay(url: "https://relay.example"))
        _ = await pathIterator.next()
        await clock.release()

        // The path-change signal publishes only after the pool synchronously
        // cancels and removes the pending eviction. Once cancelled, releasing
        // its test clock cannot pass the task's cancellation guard.
        #expect(await connection.observedCloseCallCount() == 0)
        #expect(await pool.selectedObservedPath() == .relay(url: "https://relay.example"))
    }
}

private func pollUntilTrue(
    _ condition: @escaping () async -> Bool
) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

private func drainedEvents(from log: DiagnosticLog) async -> [DiagnosticEvent] {
    for _ in 0..<400 {
        let report = await log.snapshot()
        if report.events.contains(where: { $0.code == .sessionClosed }) {
            return report.events
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await log.snapshot().events
}
