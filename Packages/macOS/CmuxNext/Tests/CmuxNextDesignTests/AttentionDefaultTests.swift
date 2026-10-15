@testable import CmuxNextDesign
import Testing

/// A pane that needs attention draws no ring by default; the sidebar status glyph and the tab
/// mark carry it (Lawrence via Leo, 2026-10-14: we may not want attention rings by default).
/// The ring stays an opt-in setting: `steady` (clearly visible, one soft swell) or `blink`.
@Suite struct AttentionDefaultTests {
    @Test func noRingByDefault() {
        #expect(AttentionSettings().style == .none)
    }

    @Test func theSidebarAndTheTabCarryAttention() {
        let settings = AttentionSettings()
        #expect(settings.showsOnSidebar)
        #expect(settings.showsOnTab)
    }

    @Test func ringStylesStayAvailable() {
        #expect(AttentionStyle.allCases.contains(.steady))
        #expect(AttentionStyle.allCases.contains(.blink))
        #expect(AttentionStyle.allCases.contains(.pulse))
    }
}
