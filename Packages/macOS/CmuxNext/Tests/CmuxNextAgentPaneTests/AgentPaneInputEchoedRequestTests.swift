import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Startup time to first interaction: the page reports the first key the person typed showing in the
/// composer (`pane.inputEchoed`, composerInputEcho.ts) and the app marks `agent_pane.input_echoed`,
/// which a release build's launch-marks pipe carries to a harness.
@MainActor
struct AgentPaneInputEchoedRequestTests {
    @Test func decodesTheReport() {
        let request = AgentPaneRequest(body: ["method": "pane.inputEchoed", "params": [String: Any]()])
        #expect(request == .inputEchoed)
        // A page that sends no params still counts.
        #expect(AgentPaneRequest(body: ["method": "pane.inputEchoed"]) == .inputEchoed)
        #expect(AgentPageOps.methods["pane.inputEchoed"] == "pane.inputEchoed")
        #expect(String(describing: request) == "inputEchoed")
    }
}
