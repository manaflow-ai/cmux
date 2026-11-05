@testable import CmuxNextAgentPane
import CmuxNextDesign
import Testing

/// Debug Settings `icons.family` (Lucas 2026-10-17): the agent pages lay the cmux custom family over their
/// icon pack when the host sets `data-icon-family`. The shipped pack sets nothing.
///
/// Every tunable other than the family is passed at its shipped default, so the pack case is empty and the
/// custom case holds `icon-family` alone.
struct IconFamilyAttributeTests {
    @Test func thePackSetsNoAttribute() {
        #expect(IconFamily.tunable.defaultValue == .pack)
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, iconFamily: .pack).isEmpty)
    }

    @Test func theCustomFamilySetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, iconFamily: .custom)
            == ["icon-family": "custom"])
    }

    @Test func theOptionalNekoFamilySetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, iconFamily: .neko)
            == ["icon-family": "neko"])
    }

    @Test func theOptionalNekoFamilySetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, iconFamily: .neko)
            == ["icon-family": "neko"])
    }

    /// Turning another tunable off adds its own attribute beside the family's; neither hides the other,
    /// and the pack still adds nothing of its own.
    @Test func anotherAttributeRidesAlongsideTheFamily() {
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, needsYouPill: false, iconFamily: .pack)
            == ["needs-you-pill": "off"])
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, needsYouPill: false, iconFamily: .custom)
            == ["needs-you-pill": "off", "icon-family": "custom"])
        #expect(AgentPaneTunables.attributes(topStripStyle: .default, needsYouPill: false, iconFamily: .neko)
            == ["needs-you-pill": "off", "icon-family": "neko"])
    }
}
