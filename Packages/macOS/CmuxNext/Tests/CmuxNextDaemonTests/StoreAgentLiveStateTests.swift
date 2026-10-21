import Testing
@testable import CmuxNextDaemon

/// A sidebar row spins while one of its tabs has a working agent (#22995). The store must not
/// keep a working or waiting agent it can no longer hear end: after a lost connection or a
/// daemon shutdown (a crash, a restart mid-turn, another computer offline), and after an
/// overflow that may have dropped the `agent-changed` that ended a turn.
@MainActor
struct StoreAgentLiveStateTests {
    private func store() -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1), TabSnapshot(surface: 2), TabSnapshot(surface: 3)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        store.apply(.agentChanged(AgentStatus(surface: 1, state: .working, source: "hook", agent: "claude", updatedAtMs: 100)))
        store.apply(.agentChanged(AgentStatus(surface: 2, state: .blocked, source: "hook", agent: "codex", updatedAtMs: 100)))
        store.apply(.agentChanged(AgentStatus(surface: 3, state: .idle, source: "hook", agent: "claude", updatedAtMs: 100)))
        return store
    }

    @Test(arguments: [DaemonEvent.disconnected(reason: "socket closed"), .daemonShutdown])
    func aClosedConnectionLeavesNoWorkingOrWaitingAgent(_ event: DaemonEvent) {
        let store = store()
        #expect(store.tab(surface: 1)?.agent?.state == .working)
        store.apply(event)
        // Still named (brand, session), in the neutral state every view hides.
        #expect(store.tab(surface: 1)?.agent?.state == .unknown)
        #expect(store.tab(surface: 1)?.agent?.agent == "claude")
        #expect(store.tab(surface: 2)?.agent?.state == .unknown)
        #expect(store.tab(surface: 3)?.agent?.state == .idle)

        // The reconnect's seed brings back what still runs, with no new prompted turn.
        let prompted = store.agents.lastPromptBySurface[1]
        store.apply(agents: [AgentStatus(surface: 1, state: .working, source: "hook", agent: "claude", updatedAtMs: 100)])
        #expect(store.tab(surface: 1)?.agent?.state == .working)
        #expect(store.tab(surface: 2)?.agent == nil)
        #expect(store.agents.lastPromptBySurface[1] == prompted)
    }

    @Test func aConnectOrAnOverflowListsTheAgentsAgain() {
        func batch(_ events: DaemonEvent...) -> [DaemonEventEnvelope] {
            events.enumerated().map { DaemonEventEnvelope(sequence: UInt64($0.offset + 1), event: $0.element) }
        }
        let identity = DaemonIdentity(capabilities: [], generation: "boot")
        #expect(DaemonStore.seedsAgents(batch(.connected(identity, generationChanged: false))))
        // An overflow may have dropped the `agent-changed` that ended a turn.
        #expect(DaemonStore.seedsAgents(batch(.titleChanged(surface: 1, title: "t"), .overflow("app event inbox exceeded"))))
        #expect(!DaemonStore.seedsAgents(batch(.titleChanged(surface: 1, title: "t"), .treeChanged(transaction: nil))))
    }
}
