import CmuxNextAgentPane
import Testing

@Suite("Agent pane Run attach")
struct AgentPaneRunAttachTests {
    @Test("decodes a bounded remote target without accepting arbitrary schemes")
    func decodesTarget() {
        let request = AgentPaneRequest(body: [
            "method": "run.attach",
            "params": [
                "runId": "run-1",
                "attemptId": "attempt-1",
                "route": "wss://worker.example/v1/link?token=short",
                "token": "short",
                "session": "session-1",
                "expiresAtUnix": 1_800_000_000,
            ],
        ])
        guard case .runAttach(let target) = request else {
            Issue.record("run.attach should decode into a typed native target")
            return
        }
        #expect(target.runID == "run-1")
        #expect(target.attemptID == "attempt-1")
        #expect(target.shellCommand.contains("cmux remote connect"))

        let refused = AgentPaneRequest(body: [
            "method": "run.attach",
            "params": ["runId": "run-1", "attemptId": "attempt-1", "route": "file:///tmp/secret", "token": "short", "session": "session-1", "expiresAtUnix": 1_800_000_000],
        ])
        if case .runAttach = refused { Issue.record("run.attach must refuse non-remote routes") }
    }
}
