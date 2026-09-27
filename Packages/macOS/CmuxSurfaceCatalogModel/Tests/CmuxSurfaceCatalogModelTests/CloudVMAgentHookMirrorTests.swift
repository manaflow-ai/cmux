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

    @Test("A new agent replays its session start before its state")
    func newAgentReplaysSessionThenState() {
        var mirror = CloudVMAgentHookMirror()
        let events = mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: ["term_1"])
        #expect(kinds(events) == [.sessionStart, .promptSubmit])
        #expect(events.allSatisfy { $0.agent == "claude" && $0.agentSessionID == "claude-session-a" })
    }

    @Test("Each daemon state maps to its hook transition")
    func stateTransitions() {
        var mirror = CloudVMAgentHookMirror()
        _ = mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: ["term_1"])
        #expect(kinds(mirror.reconcile(agents: [claude(state: "blocked")], routableTerminalIDs: ["term_1"])) == [.needsInput])
        #expect(kinds(mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: ["term_1"])) == [.promptSubmit])
        #expect(kinds(mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: ["term_1"])) == [.stop])
        #expect(mirror.reconcile(agents: [claude(state: "unknown")], routableTerminalIDs: ["term_1"]).isEmpty)
    }

    @Test("Repeated snapshots of the same roster emit nothing")
    func repeatedSnapshotsAreDeduped() {
        var mirror = CloudVMAgentHookMirror()
        _ = mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: ["term_1"])
        #expect(mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: ["term_1"]).isEmpty)
        #expect(mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: ["term_1"]).isEmpty)
    }

    @Test("A changed session id starts the new session and reasserts state")
    func sessionChange() {
        var mirror = CloudVMAgentHookMirror()
        _ = mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: ["term_1"])
        let events = mirror.reconcile(
            agents: [claude(state: "idle", session: "claude-session-b")],
            routableTerminalIDs: ["term_1"]
        )
        #expect(kinds(events) == [.sessionStart, .stop])
        #expect(events.allSatisfy { $0.agentSessionID == "claude-session-b" })
    }

    @Test("Without a session id, status still flows and no session start is sent")
    func missingSessionID() {
        var mirror = CloudVMAgentHookMirror()
        let first = mirror.reconcile(agents: [claude(state: "working", session: nil)], routableTerminalIDs: ["term_1"])
        #expect(kinds(first) == [.promptSubmit])
        #expect(first.first?.agentSessionID == nil)
        #expect(!first[0].payload.contains("session_id"))

        // The id arriving later is a session start; losing it again is not a change.
        let second = mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: ["term_1"])
        #expect(kinds(second) == [.sessionStart, .promptSubmit])
        #expect(mirror.reconcile(agents: [claude(state: "working", session: nil)], routableTerminalIDs: ["term_1"]).isEmpty)
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
            CloudVMAgentState(terminalID: "term_1", state: "working", source: "hook", agent: "opencode"),
            CloudVMAgentState(terminalID: "term_2", state: "working", source: "socket", agent: nil),
        ]
        #expect(mirror.reconcile(agents: agents, routableTerminalIDs: ["term_1", "term_2"]).isEmpty)
        #expect(mirror.reconcile(agents: [], routableTerminalIDs: []).isEmpty)
    }

    @Test("Claude Code adapter ids map to the claude hook agent")
    func claudeCodeAdapterID() {
        var mirror = CloudVMAgentHookMirror()
        let agent = CloudVMAgentState(terminalID: "term_1", state: "idle", source: "hook", agent: "claude-code")
        let events = mirror.reconcile(agents: [agent], routableTerminalIDs: ["term_1"])
        #expect(events.map(\.agent) == ["claude"])
    }

    @Test("An agent without a local pane waits and catches up when one opens")
    func unroutableAgentCatchesUp() {
        var mirror = CloudVMAgentHookMirror()
        #expect(mirror.reconcile(agents: [claude(state: "working")], routableTerminalIDs: []).isEmpty)
        #expect(kinds(mirror.reconcile(agents: [claude(state: "blocked")], routableTerminalIDs: ["term_1"])) == [.sessionStart, .needsInput])

        // Losing the pane does not end the session or replay anything.
        #expect(mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: []).isEmpty)
        #expect(kinds(mirror.reconcile(agents: [claude(state: "idle")], routableTerminalIDs: ["term_1"])) == [.stop])
    }

    @Test("Payloads carry only the session id, event name, and notification type")
    func payloadShape() throws {
        let event = CloudVMAgentHookEvent(terminalID: "term_1", agent: "claude", kind: .needsInput, agentSessionID: "s1")
        #expect(event.subcommand == "notification")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(event.payload.utf8)) as? [String: String]
        )
        #expect(object == [
            "session_id": "s1",
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
        ])
        let stop = CloudVMAgentHookEvent(terminalID: "term_1", agent: "claude", kind: .stop, agentSessionID: nil)
        #expect(stop.payload == #"{"hook_event_name":"Stop"}"#)
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
