import CmuxNextAgentPane
import CmuxNextSettings
import Testing

/// `pane.subagentPanes {show}` (the summary card's Open subagents in panes switch): the host writes
/// `agentPane.subagentPanes` in cmux.json, and nothing without a flag.
struct AgentPaneSubagentPanesRequestTests {
    @Test(arguments: [true, false])
    func theSwitchWritesTheSetting(_ on: Bool) {
        let request = AgentPaneRequest(body: ["method": "pane.subagentPanes", "params": ["show": on]])
        #expect(request == .composerSetting(path: ["agentPane", "subagentPanes"], show: on))
    }

    @Test func noFlagIsRefused() {
        let request = AgentPaneRequest(body: ["method": "pane.subagentPanes", "params": ["show": "on"]])
        #expect(request == .unsupported("pane.subagentPanes"))
    }
}
