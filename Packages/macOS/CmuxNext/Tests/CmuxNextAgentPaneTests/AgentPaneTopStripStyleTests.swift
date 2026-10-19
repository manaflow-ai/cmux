import Testing
@testable import CmuxNextAgentPane

/// `agentPane.debug.topStripStyle`: the default sets no attribute, so the page draws as before; the
/// variants set `data-top-strip` on `<html>` beside the other tunables' attributes.
struct AgentPaneTopStripStyleTests {
    @Test func defaultSetsNoAttribute() {
        #expect(AgentPaneTunables.topStripStyle.descriptor.key == "agentPane.debug.topStripStyle")
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default).isEmpty)
    }

    @Test(arguments: [AgentPaneTopStripStyle.bump, .plain, .tray])
    func variantSetsItsAttribute(style: AgentPaneTopStripStyle) {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: style) == ["top-strip": style.rawValue])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: style)
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

struct AgentPaneReasoningSliderStyleTests {
    @Test func offersAccentAndMinimalWithAccentAsTheDefault() {
        #expect(AgentPaneReasoningSliderStyle.allCases.map(\.rawValue) == ["accent", "minimal"])
        #expect(AgentPaneTunables.reasoningSliderStyle.descriptor.key == "agent.reasoningSliderStyle")
        #expect(AgentPaneTunables.reasoningSliderStyle.value == .accent)
        #expect(AgentPaneTunables.all.contains { $0.key == "agent.reasoningSliderStyle" })
    }
}
