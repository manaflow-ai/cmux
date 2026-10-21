@testable import CmuxNextDesign
import Testing

/// The attention ring keeps its default (Lawrence 2026-10-19, u2414: it reads on focus and click
/// and draws the notification blue); the sidebar status glyph and the tab mark carry attention
/// too. `steady` (clearly visible, one soft swell) is an opt-in style.
@Suite struct AttentionDefaultTests {
    @Test func theRingBlinksByDefault() {
        #expect(AttentionSettings().style == .blink)
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
