@testable import CmuxNextAgentPane
import CmuxNextDesign
import Testing

/// Debug Settings `icons.family` (Lucas 2026-10-17): the agent pages lay the cmux custom family over their
/// icon pack when the host sets `data-icon-family`. The shipped pack sets nothing.
///
/// Every other tunable is passed at its shipped default, so these two cases see `icon-family` alone.
/// `foldLongThoughts` defaults to true (Leo 2026-10-18, #20963): passing false asks
/// ``AgentPaneTunables/attributes(foldLongThoughts:topStripStyle:thoughtHeader:liveThoughtViewport:thoughtFoldThreshold:needsYou:needsYouPill:turnPreviewCards:streamWords:iconFamily:)``
/// for `fold-long-thoughts=off` as well, which is what it has always answered, so the first case
/// below could never be empty as written when it landed with #24673.
struct IconFamilyAttributeTests {
    @Test func thePackSetsNoAttribute() {
        #expect(IconFamily.tunable.defaultValue == .pack)
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, iconFamily: .pack).isEmpty)
    }

    @Test func theCustomFamilySetsItsAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: true, topStripStyle: .default, iconFamily: .custom)
            == ["icon-family": "custom"])
    }

    /// Turning a second tunable off adds its own attribute beside this one; neither hides the other.
    @Test func theCustomFamilyRidesAlongsideAnotherAttribute() {
        #expect(AgentPaneTunables.attributes(foldLongThoughts: false, topStripStyle: .default, iconFamily: .custom)
            == ["fold-long-thoughts": "off", "icon-family": "custom"])
    }
}
