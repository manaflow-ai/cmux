@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The chat's first-input launch mark: the page's `pane.inputEchoed` (webviews inputEchoMark.ts, once per page life)
/// decodes, is served on the page host, and is boot traffic the host answers without touching the chat.
/// Leo, 2026-11-22: "we should be able to just show it up as fast as the terminal does."
@MainActor @Suite struct AgentPaneInputEchoedTests {
    @Test func theReportDecodesAndIsServed() {
        #expect(AgentPaneRequest(body: ["method": "pane.inputEchoed"]) == .inputEchoed)
        #expect(AgentPaneRequest(body: ["method": "pane.inputEchoed", "params": [:]]) == .inputEchoed)
        #expect(AgentPageOps.methods["pane.inputEchoed"] == "pane.inputEchoed", "the page host refuses the op")
    }
}
