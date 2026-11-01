@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// The daemon store's event batches on the service's own drain batcher (`DaemonService.drainScheduler`),
/// built on a test ``MainWorkScheduler`` ticked by hand with the app's main-thread budget (review 2 of
/// pl-main-bc, findings 1 and 2).
///
/// e04d1798d04 moved the drain to the budgeted visible class and applied a batch in 32-event slices:
/// the echo of an action with no intent (close other tabs, close a workspace from the palette or the
/// CLI) waited a frame while the person typed, a transaction longer than one slice showed half applied,
/// and a sustained event rate above what one slice per frame applied grew the inbox until it collapsed
/// into an overflow and a full snapshot apply.
@MainActor @Suite struct DaemonDrainFrameTests {
    @Test func shutdownJoinsAnUnadoptedStartup() async {
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer {
            entered.continuation.finish()
            cancelled.continuation.finish()
            release.continuation.finish()
        }
        let service = DaemonService()
        service.start {
            DaemonConnection {
                try await withTaskCancellationHandler {
                    entered.continuation.yield(())
                    // task-owner: controlled startup work; the test releases and joins it on shutdown
                    let attempt = Task<DaemonEndpoint, any Error> {
                        var iterator = release.stream.makeAsyncIterator()
                        _ = await iterator.next()
                        throw CancellationError()
                    }
                    return try await attempt.value
                } onCancel: {
                    cancelled.continuation.yield(())
                }
            }
        }
        var started = entered.stream.makeAsyncIterator()
        _ = await started.next()
        #expect(service.connection == nil)
        var stopped = false
        // task-owner: the test joins this shutdown after releasing the controlled endpoint attempt
        let shutdown = Task { @MainActor in
            await service.shutdownConnectionAndWait()
            stopped = true
        }
        var cancellation = cancelled.stream.makeAsyncIterator()
        _ = await cancellation.next()
        // The cancellation handler ran on detach's main-actor turn. A cancel-only teardown
        // would have returned on that turn; a joined teardown waits for the explicit release.
        #expect(!stopped)
        release.continuation.yield(())
        await shutdown.value
        #expect(stopped && service.connection == nil && !service.isStarting)
    }

    /// One workspace, one screen, one pane with `tabs` tabs on surfaces 1...tabs.
    private func service(tabs: Int, mainWork: MainWorkScheduler) -> DaemonService {
        let service = DaemonService(mainWork: mainWork)
        let pane = PaneSnapshot(id: 1, tabs: (1...tabs).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "t") })
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        service.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        // Never started: no socket is touched.
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-drain-frame-test.sock"))
        service.store.driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: service.drainScheduler)
        return service
    }

    /// What the pump does for a non-empty inbox (`DaemonStore.run`), minus the main run loop hop.
    private func scheduleDrain(_ service: DaemonService) {
        let store = service.store
        service.drainScheduler.queue.enqueue { store.drain() }
    }

    /// Close Other Tabs has no intent: the person sees it only through the daemon's echo. The whole
    /// transaction (199 tab closes, more than one slice) applies in the next frame while a key is pending.
    @Test func anActionsEchoAppliesWholeInTheNextFrameWhileThePersonTypes() throws {
        let input = TypingInput()
        input.pending = true
        let budget = MainFrameBudget(input: input, uptimeNanos: AdvancingClock(stepNanos: 1_000_000).read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in StillFrameLink() }
        let service = service(tabs: 200, mainWork: work)
        let driver = try #require(service.store.driver)
        let transaction = ClientTransactionID(rawValue: "close-other-tabs")
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .titleChanged(surface: 1, title: "kept")))
        for surface in 2...200 {
            let delta = TabDelta(workspace: 1, screen: 1, pane: 1, surface: SurfaceID(rawValue: UInt64(surface)), index: nil,
                                 entity: TabSnapshot(surface: SurfaceID(rawValue: UInt64(surface)), title: "t"),
                                 clientTransactionID: transaction)
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(surface), event: .tabClosed(delta)))
        }
        scheduleDrain(service)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        let tabs = try #require(service.store.workspaces.first?.screens.first?.panes.first?.tabs)
        #expect(tabs.map(\.surface) == [1], "the echo waited for a later frame, or applied in part (\(tabs.count) tabs left)")
        #expect(tabs.first?.title == "kept")
        #expect(driver.inbox.bufferedCount == 0)
    }

    /// 200 agent transitions a frame (agent statuses never coalesce), with every frame's budget
    /// spent: each frame applies what arrived, so the inbox never grows, never overflows, and no
    /// full snapshot apply follows.
    @Test func aSustainedEventRateNeverGrowsTheInbox() throws {
        let budget = MainFrameBudget(uptimeNanos: AdvancingClock(stepNanos: 1_000_000).read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in StillFrameLink() }
        let service = service(tabs: 200, mainWork: work)
        let store = service.store
        let driver = try #require(store.driver)
        var sequence: UInt64 = 0
        for frame in 1...60 {
            for surface in 1...200 {
                sequence += 1
                let status = AgentStatus(surface: SurfaceID(rawValue: UInt64(surface)), state: frame.isMultiple(of: 2) ? .idle : .working,
                                         source: "hook", agent: "claude", updatedAtMs: sequence)
                _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: .agentChanged(status)))
            }
            scheduleDrain(service)
            work.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
            #expect(driver.inbox.bufferedCount == 0, "frame \(frame): \(driver.inbox.bufferedCount) events left for later frames")
            #expect(!store.isResyncing, "frame \(frame): the inbox overflowed into a snapshot")
        }
        #expect(!store.snapshotMemo.untracked)
        #expect(store.agents.bySurface[200]?.state == .idle)
    }
}

/// A clock that moves `stepNanos` at every read, so every budget check sees time spent. `read`
/// holds the clock (the budget keeps only the closure).
@MainActor
private final class AdvancingClock {
    private var now: UInt64 = 1_000_000_000
    private let step: UInt64
    init(stepNanos: UInt64) { step = stepNanos }
    var read: () -> UInt64 { { [self] in now += step; return now } }
}

@MainActor
private final class TypingInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class StillFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
