import Testing
@testable import CmuxNextAgentPane

/// Every chat lab reaches the page as an explicit on or off, including defaults.
struct AgentPaneLabsTests {
    @Test func defaultsSetEveryAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default) == [
            "lab-live-render": "on", "lab-render-guide": "on", "lab-context-meter": "off", "lab-prompt-collapse": "off",
            "lab-message-times": "off", "lab-code-wrap": "off", "lab-plan-progress": "off",
            "lab-shortcuts-help": "off"
        ])
    }

    @Test func togglesSetBothValues() {
        let labs = AgentPaneTunables.labTunables.mapValues { !$0.defaultValue }
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, labs: labs) == [
            "lab-live-render": "off", "lab-render-guide": "off", "lab-context-meter": "on", "lab-prompt-collapse": "on",
            "lab-message-times": "on", "lab-code-wrap": "on", "lab-plan-progress": "on",
            "lab-shortcuts-help": "on"
        ])
    }

    @Test func labsKeepTheOtherAttributes() {
        let attributes = AgentPaneTunables.attributes(
            foldLongThoughts: true, topStripStyle: .tray, thoughtStyle: .brain, labs: ["live-render": false])
        #expect(attributes["lab-live-render"] == "off")
        #expect(attributes["lab-render-guide"] == "on")
        #expect(attributes["lab-context-meter"] == "off")
        #expect(attributes["fold-long-thoughts"] == "on")
        #expect(attributes["top-strip"] == "tray")
        #expect(attributes["thought-style"] == "brain")
    }

    @Test func listedInDebugSettings() {
        let keys = AgentPaneTunables.all.map(\.key).filter { $0.hasPrefix("agentPane.labs.") }
        #expect(keys == [
            "agentPane.labs.liveRender", "agentPane.labs.renderGuide", "agentPane.labs.contextMeter", "agentPane.labs.promptCollapse",
            "agentPane.labs.messageTimes", "agentPane.labs.codeWrap", "agentPane.labs.planProgress",
            "agentPane.labs.shortcutsHelp"
        ])
    }
}
