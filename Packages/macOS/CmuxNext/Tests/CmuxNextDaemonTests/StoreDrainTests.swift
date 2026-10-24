import CmuxNextWakeups
@testable import CmuxNextDaemon
import Testing

/// The store's drain of the event inbox (DaemonStore+Driver.swift), through the inbox and a frame
/// scheduler with the app's budget: every agent transition reaches the roster, a batch the budget
/// cuts applies its rest next frame in order, and a resync in a slice holds the rest until after
/// the snapshot.
@MainActor @Suite struct StoreDrainTests {
    /// One workspace, one pane, `tabs` tabs on surfaces 1...tabs.
    private func store(tabs: Int, scheduler: HandFrameScheduler) -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: (1...tabs).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "old") })
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        // Never started: a snapshot request fails at once (no socket is touched).
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-store-drain-test.sock"))
        store.driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: scheduler)
        return store
    }

    private func titled(_ store: DaemonStore, _ surfaces: ClosedRange<Int>) -> [Int] {
        surfaces.filter { store.index.tabsBySurface[SurfaceID(rawValue: UInt64($0))]?.title == "new \($0)" }
    }

    /// Review 1 of pl-main-bc: the inbox coalesced `agent-changed`, but the roster records the
    /// transition from the old status to the new one (prompted turns, the timeline). A hook agent
    /// that worked, went idle and worked again inside one frame lost its finished turn and its
    /// second prompt.
    @Test func everyAgentTransitionInOneFrameReachesTheTimelineAndTheLastPrompt() throws {
        let scheduler = HandFrameScheduler(budget: MainFrameBudget())
        let store = store(tabs: 1, scheduler: scheduler)
        let driver = try #require(store.driver)
        let reports: [(AgentState, UInt64)] = [(.working, 100), (.idle, 200), (.working, 300)]
        for (index, report) in reports.enumerated() {
            let status = AgentStatus(surface: 1, state: report.0, source: "hook", agent: "claude", updatedAtMs: report.1)
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(index + 1), event: .agentChanged(status)))
        }
        scheduler.frame(timestamp: 1) { store.drain() }
        #expect(store.agents.timelines[1]?.events.map(\.kind) == [.started, .finished, .started])
        #expect(store.agents.lastPromptBySurface[1] == 300, "the second turn is the last prompt")
        #expect(store.agents.bySurface[1]?.state == .working)
    }

    /// A batch the frame's budget cuts (the person's key is pending) applies its first slice now
    /// and the rest, in order and ahead of later events, on the next frame.
    @Test func aBatchOverTheBudgetAppliesItsFirstSliceNowAndTheRestNextFrameInOrder() throws {
        let input = PendingInputStub()
        let scheduler = HandFrameScheduler(budget: MainFrameBudget(input: input, uptimeNanos: { 1_000_000_000 }))
        let store = store(tabs: 100, scheduler: scheduler)
        let driver = try #require(store.driver)
        for surface in 1...100 {
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(surface),
                                                        event: .titleChanged(surface: SurfaceID(rawValue: UInt64(surface)), title: "new \(surface)")))
        }
        input.pending = true
        scheduler.frame(timestamp: 1) { store.drain() }
        #expect(titled(store, 1...100) == Array(1...DaemonStore.drainSlice), "the first slice applies; the rest waits for the key")
        #expect(scheduler.scheduled == 1, "the rest asked for the next frame")
        scheduler.fire(timestamp: 2)
        #expect(titled(store, 1...100) == Array(1...100), "the rest applied on the next frame (a class yields one frame, never two)")
        #expect(scheduler.scheduled == 0)
    }

    /// A slice that needs a resync: the events after it are held (not applied over the stale
    /// tree) and apply after the snapshot attempt.
    @Test func aResyncInTheFirstSliceHoldsTheRestUntilAfterTheSnapshot() async throws {
        let scheduler = HandFrameScheduler(budget: MainFrameBudget())
        let store = store(tabs: 40, scheduler: scheduler)
        let driver = try #require(store.driver)
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil)))
        for surface in 1...40 {
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(surface + 1),
                                                        event: .titleChanged(surface: SurfaceID(rawValue: UInt64(surface)), title: "new \(surface)")))
        }
        scheduler.frame(timestamp: 1) { store.drain() }
        #expect(store.isResyncing)
        #expect(titled(store, 1...40) == Array(1...(DaemonStore.drainSlice - 1)), "the slice with the resync applied; the rest is held")
        // The unstarted connection fails the snapshot; the held events drain right after it.
        await store.refresh()
        #expect(!store.isResyncing)
        #expect(titled(store, 1...40) == Array(1...40))
    }
}
