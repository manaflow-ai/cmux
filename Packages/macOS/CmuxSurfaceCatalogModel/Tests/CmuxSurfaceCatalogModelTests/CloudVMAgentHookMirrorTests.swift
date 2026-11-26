import CmuxSurfaceCatalogModel
import Foundation
import Testing

struct CloudVMAgentHookMirrorTests {
    private func claude(
        _ terminalID: String = "term_1",
        state: String,
        session: String? = "claude-session-a"
    ) -> CloudVMAgentState {
        CloudVMAgentState(
            id: "agent_\(terminalID)",
            terminalID: terminalID,
            state: state,
            source: "hook",
            agent: "claude",
            agentSessionID: session
        )
    }

    private func kinds(_ events: [CloudVMAgentHookEvent]) -> [CloudVMAgentHookEvent.Kind] {
        events.map(\.kind)
    }

    @Test("A new agent with a session id replays one session start")
    func newAgentReplaysSessionStart() {
        var mirror = CloudVMAgentHookMirror()
        let events = mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: ["term_1"])
        #expect(kinds(events) == [.sessionStart])
        #expect(events.first?.agent == "claude")
        #expect(events.first?.agentSessionID == "claude-session-a")
    }

    @Test("State changes and repeated snapshots replay nothing")
    func stateChangesAreNotReplayed() {
        var mirror = CloudVMAgentHookMirror()
        _ = mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: ["term_1"])
        for state in ["blocked", "idle", "working", "idle", "unknown"] {
            #expect(mirror.reconcile(agents: [claude(state: state)], routableTerminalIDs: ["term_1"]).isEmpty)
        }
    }

    @Test("A changed session id starts the new session")
    func sessionChange() {
        var mirror = CloudVMAgentHookMirror()
        _ = mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: ["term_1"])
        let events = mirror.reconcile(
            agents: [claude(state: "idle", session: "claude-session-b")],
            routableTerminalIDs: ["term_1"]
        )
        #expect(kinds(events) == [.sessionStart])
        #expect(events.first?.agentSessionID == "claude-session-b")
    }

    @Test("An agent without a session id replays nothing until the id arrives")
    func missingSessionID() {
        var mirror = CloudVMAgentHookMirror()
        #expect(mirror.reconcile(agents: [claude(state: "working", session: nil)], routableTerminalIDs: ["term_1"]).isEmpty)
        // Leaving the roster without a known session has nothing to end.
        #expect(mirror.reconcile(agents: [], routableTerminalIDs: []).isEmpty)

        #expect(kinds(mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: ["term_1"])) == [.sessionStart])
        // Losing the id again is not a session change or an end.
        #expect(mirror.reconcile(agents: [claude(state: "working", session: nil)], routableTerminalIDs: ["term_1"]).isEmpty)
        #expect(kinds(mirror.reconcile(agents: [], routableTerminalIDs: [])) == [.sessionEnd])
    }

    @Test("An agent leaving the roster ends its session once")
    func deletedAgentEndsSession() {
        var mirror = CloudVMAgentHookMirror()
        _ = mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: ["term_1"])
        let events = mirror.reconcile(agents: [], routableTerminalIDs: [])
        #expect(kinds(events) == [.sessionEnd])
        #expect(events.first?.terminalID == "term_1")
        #expect(events.first?.agentSessionID == "claude-session-a")
        #expect(mirror.reconcile(agents: [], routableTerminalIDs: []).isEmpty)
    }

    @Test("Agents without a supported hook integration are skipped")
    func unknownAgentSkipped() {
        var mirror = CloudVMAgentHookMirror()
        let agents = [
            CloudVMAgentState(terminalID: "term_1", state: "working", source: "hook", agent: "opencode", agentSessionID: "s1"),
            CloudVMAgentState(terminalID: "term_2", state: "working", source: "socket", agent: nil, agentSessionID: "s2"),
        ]
        #expect(mirror.reconcile(agents: agents, routableTerminalIDs: ["term_1", "term_2"]).isEmpty)
        #expect(mirror.reconcile(agents: [], routableTerminalIDs: []).isEmpty)
    }

    @Test("Claude Code adapter ids map to the claude hook agent")
    func claudeCodeAdapterID() {
        var mirror = CloudVMAgentHookMirror()
        let agent = CloudVMAgentState(
            terminalID: "term_1",
            state: "idle",
            source: "hook",
            agent: "claude-code",
            agentSessionID: "s1"
        )
        let events = mirror.reconcile(agents: [agent], routableTerminalIDs: ["term_1"])
        #expect(events.map(\.agent) == ["claude"])
    }

    @Test("An agent without a local pane waits and catches up when one opens")
    func unroutableAgentCatchesUp() {
        var mirror = CloudVMAgentHookMirror()
        #expect(mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: []).isEmpty)
        #expect(kinds(mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: ["term_1"])) == [.sessionStart])

        // Losing the pane neither ends the session nor replays it again.
        #expect(mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: []).isEmpty)
        #expect(mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: ["term_1"]).isEmpty)
    }

    @Test("Payloads carry only the session id and event name")
    func payloadShape() {
        let start = CloudVMAgentHookEvent(terminalID: "term_1", agent: "claude", kind: .sessionStart, agentSessionID: "s1")
        #expect(start.subcommand == "session-start")
        #expect(start.payload == #"{"hook_event_name":"SessionStart","session_id":"s1"}"#)
        let end = CloudVMAgentHookEvent(terminalID: "term_1", agent: "claude", kind: .sessionEnd, agentSessionID: "s1")
        #expect(end.subcommand == "session-end")
        #expect(end.payload == #"{"hook_event_name":"SessionEnd","session_id":"s1"}"#)
    }

    @Test("Agent session ids outside the cmux-tui contract are dropped", arguments: [
        "..", ".", "a/b", "x; rm -rf ~", "a b", " padded ", String(repeating: "a", count: 257),
    ])
    func parserDropsUnportableAgentSessionID(id: String) {
        #expect(CmuxTuiSnapshotParser.agentSessionID(from: ["extra": ["agent_session_id": id]]) == nil)
    }

    @Test("Portable agent session ids are kept")
    func parserKeepsPortableAgentSessionID() {
        for id in ["0f8c2a4e-1b3d-4c5e-9f7a-2b4c6d8e0a1b", "a.b_c:d-e", String(repeating: "a", count: 256)] {
            #expect(CmuxTuiSnapshotParser.agentSessionID(from: ["extra": ["agent_session_id": id]]) == id)
        }
    }

    @Test("Snapshots and upsert deltas parse extra.agent_session_id")
    func parserReadsAgentSessionID() throws {
        let snapshot: [String: Any] = [
            "cursor": ["generation": "daemon-1", "revision": "2"],
            "workspaces": [["id": "ws-1", "name": "Workspace"]],
            "screens": [],
            "panes": [],
            "tabs": [],
            "terminals": [],
            "browsers": [],
            "agents": [[
                "id": "agent_1",
                "session_id": "mux-session",
                "terminal_id": "term_1",
                "state": "working",
                "source": "hook",
                "extra": ["agent": "claude", "agent_session_id": "claude-session-a"],
            ], [
                "id": "agent_2",
                "session_id": "mux-session",
                "terminal_id": "term_2",
                "state": "idle",
                "source": "hook",
                "extra": ["agent": "claude"],
            ]],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: .ssh("host")))
        #expect(state.agents.map(\.agentSessionID) == ["claude-session-a", nil])

        let delta: [String: Any] = [
            "kind": "delta",
            "changes": [[
                "kind": "upsert",
                "resource": "agent",
                "id": "agent_2",
                "value": [
                    "id": "agent_2",
                    "session_id": "mux-session",
                    "terminal_id": "term_2",
                    "state": "working",
                    "source": "hook",
                    "extra": ["agent": "claude", "agent_session_id": "claude-session-b"],
                ],
            ]],
        ]
        let next = try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: try JSONSerialization.data(withJSONObject: delta),
            cursor: CloudVMCursor(generation: "daemon-1", revision: 3),
            to: state
        ))
        #expect(next.lookupIndex.agent(terminalID: "term_2")?.agentSessionID == "claude-session-b")
    }
}
