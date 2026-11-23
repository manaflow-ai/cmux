@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The Chief Settings harness picker offers only harnesses a Chief's own turns can run on: never
/// the Chief harness (the person's chat with a Chief) nor a terminal-only harness, which the brain
/// refuses (`harness_gate`).
@Suite struct ChiefEngineHarnessListTests {
    @Test func theChiefHarnessAndTerminalHarnessesAreNotOffered() {
        let harnesses: [String: JSONValue] = [
            "chief": ["family": "chief"],
            "claude": ["family": "claude", "kind": "claude-stdio"],
            "claude-sr2": ["family": "claude-sr2", "kind": "claude-stdio"],
            "codex": ["family": "codex"],
            "shell": ["family": "shell", "kind": "terminal"],
            "opencode": ["family": "opencode"],
        ]
        #expect(AgentHarnessCenter.chiefEngines(in: harnesses) == ["claude", "claude-sr2", "codex", "opencode"])
    }
}
