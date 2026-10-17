import Testing
@testable import CmuxNextAgentPane

/// `agentPane.debug.thoughtStyle`: plain (the default) sets no attribute, so the page draws as
/// before; brain sets `data-thought-style` on `<html>` beside the other tunables' attributes.
struct AgentPaneThoughtStyleTests {
    @Test func plainSetsNoAttribute() {
        #expect(AgentPaneTunables.thoughtStyle.descriptor.key == "agentPane.debug.thoughtStyle")
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, thoughtStyle: .plain).isEmpty)
    }

    @Test func brainSetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, thoughtStyle: .brain)
            == ["thought-style": "brain"])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .tray, thoughtStyle: .brain)
            == ["thought-style": "brain", "fold-long-thoughts": "on", "top-strip": "tray"])
    }

    @Test func listedInDebugSettingsPlainFirst() {
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.thoughtStyle" })
        #expect(AgentPaneThoughtStyle.allCases.map(\.rawValue) == ["plain", "brain"])
    }
}
