import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The chat composer's first echo of a typed key at launch (`pane.inputEchoed {echoedEpochMs}`, webviews
/// launchInputEcho.ts) parses to the page's wall-clock time, for the launch mark `agent_pane.input_echoed`; a report
/// without a finite time is refused.
@Suite struct AgentPaneInputEchoedTests {
    @Test func theReportCarriesThePagesTime() {
        let request = AgentPaneRequest(body: ["method": "pane.inputEchoed", "params": ["echoedEpochMs": 1_700_000_000_250.0]])
        guard case .inputEchoed(let at) = request else { return #expect(Bool(false), "pane.inputEchoed did not parse") }
        #expect(at == Date(timeIntervalSince1970: 1_700_000_000.25))
    }

    @Test func aReportWithoutATimeIsRefused() {
        for params: [String: Any] in [[:], ["echoedEpochMs": "soon"], ["echoedEpochMs": Double.nan]] {
            let request = AgentPaneRequest(body: ["method": "pane.inputEchoed", "params": params])
            guard case .unsupported = request else { return #expect(Bool(false), "\(params) parsed") }
        }
    }
}
