import Testing
@testable import CmuxNextAgentPane

struct AgentPaneLabsTests {
    @Test func defaultsOn() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default) == ["lab-chat-viewer": "on"])
    }
    @Test func explicitOffKeepsOtherAttributes() {
        let attributes = AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .tray, labs: ["chat-viewer": false])
        #expect(attributes["lab-chat-viewer"] == "off")
        #expect(attributes["fold-long-thoughts"] == "on")
        #expect(attributes["top-strip"] == "tray")
    }
    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.map(\.key).filter { $0.hasPrefix("agentPane.labs.") } == ["agentPane.labs.chatViewer"])
    }
}
