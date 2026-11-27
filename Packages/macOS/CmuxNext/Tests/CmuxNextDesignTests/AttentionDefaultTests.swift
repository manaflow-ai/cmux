@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The attention ring is a steady blue ring by default, as in cmux classic (Austin, 2026-10-20:
/// "we should see a blue ring just appear when the agent is done"); the blink plays when the
/// person goes into the pane and the ring goes away. The sidebar status glyph and the tab mark
/// carry attention too. `blink` and `pulse` stay available.
@Suite struct AttentionDefaultTests {
    @Test func theRingIsSteadyByDefault() {
        #expect(AttentionSettings().style == .steady)
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
