import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// `pane.setDisplay {key, value}` (the chat's Text & Width popover): the host writes one
/// `agentPane.display.*` key, removes it on null, and refuses every other key.
struct AgentPaneDisplayRequestTests {
    @Test func aChatKeyWritesItsValue() {
        let request = AgentPaneRequest(body: ["method": "pane.setDisplay", "params": ["key": "agentPane.display.font.size", "value": 16]])
        #expect(request == .displaySetting(path: ["agentPane", "display", "font", "size"], value: .number(16)))
    }

    @Test func environmentPlacementWritesItsValue() {
        let request = AgentPaneRequest(body: [
            "method": "pane.setDisplay",
            "params": ["key": "agentPane.display.environment.placement", "value": "right"],
        ])
        #expect(request == .displaySetting(
            path: ["agentPane", "display", "environment", "placement"],
            value: .string("right"),
        ))
    }

    @Test func nullRemovesTheKey() {
        let request = AgentPaneRequest(body: ["method": "pane.setDisplay", "params": ["key": "agentPane.display.code.family", "value": NSNull()]])
        #expect(request == .displaySetting(path: ["agentPane", "display", "code", "family"], value: nil))
    }

    @Test(arguments: ["markdown.font.size", "terminal.fontFamily", "agentPane.showDictation"])
    func anyOtherKeyIsRefused(_ key: String) {
        let request = AgentPaneRequest(body: ["method": "pane.setDisplay", "params": ["key": key, "value": 16]])
        #expect(request == .unsupported("pane.setDisplay"))
    }
}
