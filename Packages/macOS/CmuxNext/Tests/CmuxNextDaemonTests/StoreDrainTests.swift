@testable import CmuxNextDaemon
import Testing

/// The store's drain of the event inbox (DaemonStore+Driver.swift), called as a frame would:
/// every agent transition reaches the roster, and a batch that needs a
/// resync still applies all its events (a batch is never split; DaemonDrainFrameTests in
/// CmuxNextAppTests runs it on the service's own frame class with the app's budget).
@MainActor @Suite struct StoreDrainTests {
    /// One workspace, one pane, `tabs` tabs on surfaces 1...tabs.
    private func store(tabs: Int) -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: (1...tabs).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "old") })
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        // Never started: a snapshot request fails at once (no socket is touched).
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-store-drain-test.sock"))
        store.driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: NextTurnFrameScheduler())
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
        let store = store(tabs: 1)
        let driver = try #require(store.driver)
        let reports: [(AgentState, UInt64)] = [(.working, 100), (.idle, 200), (.working, 300)]
        for (index, report) in reports.enumerated() {
            let status = AgentStatus(surface: 1, state: report.0, source: "hook", agent: "claude", updatedAtMs: report.1)
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(index + 1), event: .agentChanged(status)))
        }
        store.drain()
        #expect(store.agents.timelines[1]?.events.map(\.kind) == [.started, .finished, .started])
        #expect(store.agents.lastPromptBySurface[1] == 300, "the second turn is the last prompt")
        #expect(store.agents.bySurface[1]?.state == .working)
    }

    /// A batch with a `tree-changed`: every event of it applies in the same drain, then the snapshot
    /// is fetched (and, failing here, the store keeps what it applied).
    @Test func aBatchThatNeedsAResyncAppliesAllItsEventsFirst() async throws {
        let store = store(tabs: 40)
        let driver = try #require(store.driver)
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil)))
        for surface in 1...40 {
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(surface + 1),
                                                        event: .titleChanged(surface: SurfaceID(rawValue: UInt64(surface)), title: "new \(surface)")))
        }
        store.drain()
        #expect(store.isResyncing)
        #expect(titled(store, 1...40) == Array(1...40), "the batch applied whole before the snapshot")
        #expect(driver.inbox.bufferedCount == 0)
        // The unstarted connection fails the snapshot; the store keeps the applied events.
        await store.refresh()
        #expect(!store.isResyncing)
        #expect(titled(store, 1...40) == Array(1...40))
    }
}
