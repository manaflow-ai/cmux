import Foundation
import Testing
@testable import CmuxNextDaemon

/// `cmux://agent` links (hq#2555) resolve against the terminals whose agent
/// hooks reported a harness session. A terminal whose process exited keeps its
/// last agent report, but the session no longer runs there, so it is no
/// candidate: a live terminal later in the tree must win. A machine whose
/// daemon is not connected keeps its last tree, and none of it is reachable.
@MainActor
struct WorkspaceAgentSessionsTests {
    private func store() -> DaemonStore {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1), TabSnapshot(surface: 2)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        for surface: SurfaceID in [1, 2] {
            store.apply(.agentChanged(AgentStatus(surface: surface, state: .working, source: "hook",
                                                  session: "ses-1", agent: "claude", updatedAtMs: 10)))
        }
        return store
    }

    @Test func liveTerminalsListTheirHarnessSession() {
        let sessions = store().workspaces[0].agentHarnessSessions
        #expect(store().reachableAgentHarnessSessions.count == 2)
        #expect(sessions.map(\.session) == ["ses-1", "ses-1"])
        #expect(sessions.map(\.agent) == ["claude", "claude"])
    }

    @Test func anExitedTerminalIsNoCandidate() {
        let store = store()
        let exited = store.tab(surface: 1)?.id
        store.apply(.surfaceExited(surface: 1))
        #expect(store.tab(surface: 1)?.dead == true)
        let tabs = store.workspaces[0].agentHarnessSessions.map(\.tab)
        #expect(tabs.count == 1)
        #expect(!tabs.contains { $0 == exited })
    }

    /// A hook-reported agent publishes no `session` (the daemon drops its hook marker) and its
    /// harness session as `agent_session_id`; the link resolves the terminal by that id.
    @Test func aHookReportedTerminalListsItsAgentSessionID() throws {
        let store = store()
        let wire = #"{"surface":2,"state":"working","source":"hook","session":null,"agent":"claude","agent_session_id":"claude-session-1","updated_at_ms":11}"#
        let status = try JSONDecoder().decode(AgentStatus.self, from: Data(wire.utf8))
        #expect(status.agentSessionID == "claude-session-1")
        store.apply(.agentChanged(status))
        let sessions = store.workspaces[0].agentHarnessSessions
        #expect(sessions.map(\.session) == ["ses-1", "claude-session-1"])
        #expect(sessions.last?.tab == store.tab(surface: 2)?.id)
    }

    /// A hook's SessionEnd reports `done` and keeps the id; the session no longer runs there.
    @Test func anEndedSessionIsNoCandidate() {
        let store = store()
        store.apply(.agentChanged(AgentStatus(surface: 1, state: .done, source: "hook", agent: "claude",
                                              agentSessionID: "ses-1", updatedAtMs: 12)))
        #expect(store.workspaces[0].agentHarnessSessions.map(\.tab) == [store.tab(surface: 2)?.id].compactMap { $0 })
    }

    /// The harness session a tab's agent runs (Copy Session ID and agent links): the hook's id
    /// first, else a direct report's session; hook bookkeeping markers are none.
    @Test func harnessSessionIDPrefersTheHookID() {
        #expect(AgentStatus(surface: 1, state: .working, session: "cmux-hook-sequence:3", agentSessionID: "h-1").harnessSessionID == "h-1")
        #expect(AgentStatus(surface: 1, state: .working, session: "direct-1").harnessSessionID == "direct-1")
        #expect(AgentStatus(surface: 1, state: .done, session: "cmux-hook-ended:4").harnessSessionID == nil)
        #expect(AgentStatus(surface: 1, state: .idle, session: "").harnessSessionID == nil)
    }

    @Test(arguments: [DaemonEvent.disconnected(reason: "socket closed"), .daemonShutdown])
    func aDisconnectedMachineHasNoReachableSession(_ event: DaemonEvent) {
        let store = store()
        store.apply(event)
        #expect(store.workspaces[0].agentHarnessSessions.count == 2)
        #expect(store.reachableAgentHarnessSessions.isEmpty)
    }
}
