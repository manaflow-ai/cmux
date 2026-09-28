import CmuxSurfaceCatalogModel
import Testing

@Suite struct SurfaceAgentBadgeIdentityTests {
    @Test func identityIsTheAdapterNotTheProvenance() {
        #expect(SurfaceAgentBadge(state: "working", source: "hook", agent: "claude").agentIdentity == "claude")
        #expect(SurfaceAgentBadge(state: "working", source: "claude-code").agentIdentity == "claude")
        #expect(SurfaceAgentBadge(state: "working", source: "plugin", agent: " OpenCode ").agentIdentity == "opencode")
        #expect(SurfaceAgentBadge(state: "working", source: "hook").agentIdentity == nil)
        #expect(SurfaceAgentBadge(state: "working", source: "hook", agent: ";;").agentIdentity == nil)
    }

    @Test func daemonStatesUseTheAgentSessionVocabulary() {
        #expect(SurfaceAgentBadge(state: "blocked").sessionState == "needs_input")
        #expect(SurfaceAgentBadge(state: "done").sessionState == "ended")
        #expect(SurfaceAgentBadge(state: "Working").sessionState == "working")
        #expect(SurfaceAgentBadge(state: "idle").sessionState == "idle")
        #expect(SurfaceAgentBadge(state: "unknown").sessionState == "unknown")
        #expect(SurfaceAgentBadge(state: "compacting").sessionState == "compacting")
    }

    @Test func catalogTerminalsCarryTheAgentSessionID() {
        let snapshot: [String: Any] = [
            "terminals": [["id": "term_1", "title": "claude", "running": true]],
            "agents": [[
                "id": "agent_1",
                "session_id": "mux-session",
                "terminal_id": "term_1",
                "state": "blocked",
                "source": "hook",
                "extra": ["agent": "claude", "agent_session_id": "claude-session-a"],
            ]],
        ]
        let badge = CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: .ssh("host")).first?.agent
        #expect(badge?.agentSessionID == "claude-session-a")
        #expect(badge?.agentIdentity == "claude")
        #expect(badge?.sessionState == "needs_input")
    }
}
