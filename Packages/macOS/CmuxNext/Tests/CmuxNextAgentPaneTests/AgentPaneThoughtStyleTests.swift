import Testing
@testable import CmuxNextAgentPane

/// `agentPane.debug.thoughtStyle`: plain (the default) sets no thought attribute, so the page draws as
/// before; brain sets `data-thought-style` on `<html>` beside the other tunables' attributes.
struct AgentPaneThoughtStyleTests {
    @Test func plainSetsNoAttribute() {
        #expect(AgentPaneTunables.thoughtStyle.descriptor.key == "agentPane.debug.thoughtStyle")
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, thoughtStyle: .plain)
            .filter { !$0.key.hasPrefix("lab-") }.isEmpty)
    }

    @Test func brainSetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, thoughtStyle: .brain)
            .filter { !$0.key.hasPrefix("lab-") }
            == ["thought-style": "brain"])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .tray, thoughtStyle: .brain)
            .filter { !$0.key.hasPrefix("lab-") }
            == ["thought-style": "brain", "fold-long-thoughts": "on", "top-strip": "tray"])
    }

    @Test func listedInDebugSettingsPlainFirst() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtStyle" })
        #expect(AgentPaneThoughtStyle.allCases.map(\.rawValue) == ["plain", "brain"])
    }
}
