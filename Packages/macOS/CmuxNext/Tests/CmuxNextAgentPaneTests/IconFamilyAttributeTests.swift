@testable import CmuxNextAgentPane
import CmuxNextDesign
import Testing

/// Debug Settings `icons.family` (Lucas 2026-10-17): the agent pages lay the cmux custom family over their
/// icon pack when the host sets `data-icon-family`. The shipped pack sets nothing.
struct IconFamilyAttributeTests {
    @Test func thePackSetsNoAttribute() {
        #expect(IconFamily.tunable.defaultValue == .pack)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, iconFamily: .pack).isEmpty)
    }

    @Test func theCustomFamilySetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, iconFamily: .custom)
            == ["icon-family": "custom"])
    }
}
