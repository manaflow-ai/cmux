@testable import CmuxNextAgentPane
import CmuxNextDesign
import Testing

/// Debug Settings `icons.family` (Lucas 2026-10-17): the agent pages lay the cmux custom family over their
/// icon pack when the host sets `data-icon-family`. The shipped pack sets nothing.
///
/// Every tunable other than the family is passed at its shipped default, so the pack case is empty and the
/// custom case holds `icon-family` alone. `foldLongThoughts` defaults to true (Leo 2026-10-18, #20963):
/// passing false asks
/// ``AgentPaneTunables/attributes(foldLongThoughts:topStripStyle:thoughtHeader:liveThoughtViewport:thoughtFoldThreshold:needsYou:needsYouPill:turnPreviewCards:streamWords:iconFamily:)``
/// for `fold-long-thoughts=off` as well, which is what it has always answered, so the pack case could
/// never be empty as it was written when it landed with #24673.
struct IconFamilyAttributeTests {
    @Test func thePackSetsNoAttribute() {
        #expect(IconFamily.tunable.defaultValue == .pack)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, iconFamily: .pack).isEmpty)
    }

    @Test func theCustomFamilySetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, iconFamily: .custom)
            == ["icon-family": "custom"])
    }

    /// Turning another tunable off adds its own attribute beside the family's; neither hides the other,
    /// and the pack still adds nothing of its own.
    @Test func anotherAttributeRidesAlongsideTheFamily() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, iconFamily: .pack)
            == ["fold-long-thoughts": "off"])
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, iconFamily: .custom)
            == ["fold-long-thoughts": "off", "icon-family": "custom"])
    }
}
