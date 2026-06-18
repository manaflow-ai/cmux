import CmuxSwiftRender
import Foundation
import Testing
@testable import CmuxSidebarInterpreterClient

/// Supervision tests for ``RenderWorkerClient`` against the headless
/// `cmux-sidebar-render-fixture` (announces a pid-derived context id, acks
/// scenes, answers pointers with a canned action, and crashes/hangs on env
/// tokens), so the spawn → announce → ack → crash → respawn cycle is verified
/// through a real process boundary without AppKit.
@Suite(.serialized) struct RenderWorkerClientTests {
    @Test func announcesContextOnSpawn() async {
        let client = RenderWorkerClient(executableURL: renderFixtureURL())
        let collector = RenderEventCollector(stream: await client.subscribe())
        await client.updateScene(filePath: "/tmp/sidebar.swift", state: [:], topInset: 0, bottomInset: 0)
        let events = await collector.waitForEvents(count: 1)
        await client.shutdown()
        guard case .context = events.first else {
            Issue.record("expected a context announcement, got \(events)")
            return
        }
    }

    @Test func forwardsPointerEventsAndSurfacesActions() async {
        let client = RenderWorkerClient(executableURL: renderFixtureURL())
        let collector = RenderEventCollector(stream: await client.subscribe())
        await client.updateScene(filePath: "/tmp/sidebar.swift", state: [:], topInset: 0, bottomInset: 0)
        await client.forward(RenderPointerEvent(kind: .down, x: 10, y: 10))
        let events = await collector.waitForEvents(count: 2)
        await client.shutdown()
        #expect(events.count == 2)
        guard case .context = events.first else {
            Issue.record("expected context first, got \(events)")
            return
        }
        #expect(events.last == .action(ButtonAction(commands: [])))
    }

    /// A pointer interaction with no prior scene must still spawn the worker
    /// (the host can race a click against the first data tick) and surface the
    /// resulting action.
    @Test func pointerBeforeAnySceneSpawnsWorker() async {
        let client = RenderWorkerClient(executableURL: renderFixtureURL())
        let collector = RenderEventCollector(stream: await client.subscribe())
        await client.forward(RenderPointerEvent(kind: .down, x: 1, y: 1))
        let events = await collector.waitForEvents(count: 2)
        await client.shutdown()
        guard case .context = events.first else {
            Issue.record("expected spawn context, got \(events)")
            return
        }
        #expect(events.last == .action(ButtonAction(commands: [])))
    }

    /// The headline guarantee: a renderer crash kills only the worker. The
    /// next scene update relaunches a fresh worker, which re-announces a new
    /// context id the host swaps to.
    @Test func survivesAWorkerCrashAndReannouncesContext() async {
        let crashToken = "/tmp/__CRASH_THE_RENDER_WORKER__.swift"
        let client = RenderWorkerClient(
            executableURL: renderFixtureURL(),
            environment: ["CMUX_RENDER_FIXTURE_CRASH_TOKEN": crashToken]
        )
        let collector = RenderEventCollector(stream: await client.subscribe())

        await client.updateScene(filePath: crashToken, state: [:], topInset: 0, bottomInset: 0)
        let first = await collector.waitForEvents(count: 1)

        // The host sends scene ticks every second; relaunch happens on the
        // next send after the death is noticed. Tick until recovery.
        var all = [RenderWorkerEvent]()
        for _ in 0..<20 where all.count < 2 {
            await client.updateScene(filePath: "/tmp/recovered.swift", state: [:], topInset: 0, bottomInset: 0)
            all = await collector.waitForEvents(count: 2, deadline: .milliseconds(500))
        }
        await client.shutdown()

        guard case let .context(firstContext) = first.first,
              all.count >= 2, case let .context(secondContext) = all[1] else {
            Issue.record("expected two context announcements, got \(all)")
            return
        }
        #expect(firstContext != secondContext, "a respawned worker must announce a fresh context")
    }

    /// A renderer that never acks a scene is presumed hung: the watchdog
    /// discards it, and the next scene update relaunches a fresh worker that
    /// replays the latest scene.
    @Test func discardsAHungWorkerAndRecovers() async throws {
        let hangToken = "/tmp/__HANG_THE_RENDER_WORKER__.swift"
        let client = RenderWorkerClient(
            executableURL: renderFixtureURL(),
            ackTimeout: .milliseconds(300),
            environment: ["CMUX_RENDER_FIXTURE_HANG_TOKEN": hangToken]
        )
        let collector = RenderEventCollector(stream: await client.subscribe())

        await client.updateScene(filePath: hangToken, state: [:], topInset: 0, bottomInset: 0)
        let first = await collector.waitForEvents(count: 1)
        guard case let .context(firstContext) = first.first else {
            Issue.record("expected initial context before hang, got \(first)")
            await client.shutdown()
            return
        }

        // Let the ack watchdog expire and discard the (simulated) hung worker.
        let discarded = await waitForContextReset(client, after: firstContext)
        #expect(discarded, "expected hung worker to be discarded after ack timeout")

        // Tick like the host until the fresh worker announces itself.
        var recoveryContext: UInt32?
        for _ in 0..<20 where recoveryContext == nil {
            await client.updateScene(filePath: "/tmp/after-hang.swift", state: [:], topInset: 0, bottomInset: 0)
            let events = await collector.waitForEvents(count: 2, deadline: .milliseconds(500))
            recoveryContext = events.compactMap { event -> UInt32? in
                guard case let .context(context) = event, context != firstContext else { return nil }
                return context
            }.first
        }
        await client.shutdown()

        guard let recoveryContext else {
            Issue.record("expected recovery context after hang")
            return
        }
        #expect(firstContext != recoveryContext, "recovery must come from a fresh worker process")
    }

    private func waitForContextReset(
        _ client: RenderWorkerClient,
        after initialContext: UInt32,
        deadline: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        var sawInitialContext = false
        while clock.now < end {
            let contextId = await MainActor.run { client.contextCache.contextId }
            if contextId == initialContext { sawInitialContext = true }
            if sawInitialContext, contextId == nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

/// Drains a ``RenderWorkerClient/subscribe()`` stream into an ordered log and lets
/// tests await "at least N events" with a bounded deadline.
///
/// A single long-lived consumer per test, because `AsyncStream` is unicast and
/// terminates when an iterator is cancelled — racing short-lived `for await`
/// loops against deadlines would tear the stream down after the first wait.
private actor RenderEventCollector {
    private var events: [RenderWorkerEvent] = []
    private var nextWaiterID = 0
    private var waiters: [Int: (threshold: Int, continuation: CheckedContinuation<[RenderWorkerEvent], Never>)] = [:]
    private var pump: Task<Void, Never>?

    init(stream: AsyncStream<RenderWorkerEvent>) {
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<RenderWorkerEvent>) {
        guard pump == nil else { return }
        pump = Task {
            for await event in stream {
                await self.ingest(event)
            }
        }
    }

    private func ingest(_ event: RenderWorkerEvent) {
        events.append(event)
        let satisfied = waiters.filter { $0.value.threshold <= events.count }
        for (id, waiter) in satisfied {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: events)
        }
    }

    /// Returns the full event log once it holds at least `count` events, or
    /// whatever has arrived when `deadline` expires (bounded, cancellable
    /// test-only deadline).
    func waitForEvents(count: Int, deadline: Duration = .seconds(10)) async -> [RenderWorkerEvent] {
        if events.count >= count { return events }
        let id = nextWaiterID
        nextWaiterID += 1
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            await self?.expire(id)
        }
        let result = await withCheckedContinuation { continuation in
            waiters[id] = (count, continuation)
        }
        expiry.cancel()
        return result
    }

    private func expire(_ id: Int) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: events)
    }
}
