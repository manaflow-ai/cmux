import Testing
@testable import CmuxNextAgentPane

/// `agentPane.debug.topStripStyle`: the default sets no top strip attribute, so the page draws as before; the
/// variants set `data-top-strip` on `<html>` beside the other tunables' attributes.
struct AgentPaneTopStripStyleTests {
    @Test func defaultSetsNoAttribute() {
        #expect(AgentPaneTunables.topStripStyle.descriptor.key == "agentPane.debug.topStripStyle")
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default)
            .filter { !$0.key.hasPrefix("lab-") }.isEmpty)
    }

    @Test(arguments: [AgentPaneTopStripStyle.bump, .plain, .tray])
    func variantSetsItsAttribute(style: AgentPaneTopStripStyle) {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: style)
            .filter { !$0.key.hasPrefix("lab-") } == ["top-strip": style.rawValue])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: style)
            .filter { !$0.key.hasPrefix("lab-") }
            == ["top-strip": style.rawValue, "fold-long-thoughts": "on"])
    }

    @Test func listedInDebugSettings() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.topStripStyle" })
    }
}

extension AgentPaneTopStripStyleTests {
    /// The Debug menu offers the four values in order, the default first and unchanged.
    @Test func offersTrayAfterTheOthers() {
        #expect(AgentPaneTopStripStyle.allCases.map(\.rawValue) == ["default", "bump", "plain", "tray"])
        #expect(AgentPaneTunables.topStripStyle.descriptor.key == "agentPane.debug.topStripStyle")
    }
}
