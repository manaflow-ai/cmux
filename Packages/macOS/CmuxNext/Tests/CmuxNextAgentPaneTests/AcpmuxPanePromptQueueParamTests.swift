import Foundation
import Testing
@testable import CmuxNextAgentPane

/// acpmux stops a running turn for a prompt that does not ask to queue (2026-10-20), so the pane's
/// Enter mid-turn sends `_meta.acpmux.queue: true`. The pane's params rule (P1) must let it through,
/// and still refuse a key the pane never sends.
@Suite
struct AcpmuxPanePromptQueueParamTests {
    private func prompt(_ acpmux: [String: Any]) -> [String: Any] {
        ["method": "session/prompt",
         "params": ["sessionId": "s1", "prompt": [["type": "text", "text": "after the turn"]], "_meta": ["acpmux": acpmux]]]
    }

    @Test func aQueuedPromptPassesTheParamsRule() {
        #expect(!AcpmuxPaneMethods.breaksParamsRule(prompt(["promptId": "p1", "queue": true]), modeFields: nil))
    }

    @Test func anUnknownPromptKeyStillBreaksIt() {
        #expect(AcpmuxPaneMethods.breaksParamsRule(prompt(["promptId": "p1", "busyPrompt": "queue"]), modeFields: nil))
    }
}
