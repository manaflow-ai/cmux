@testable import CmuxNextDesign
import Testing

/// A pane that needs attention shows a steady ring by default, never a blink
/// (Leo, 2026-10-14: blinking is not a default; `blink` and `pulse` stay options).
@Suite struct AttentionDefaultTests {
    @Test func defaultRingIsSteady() {
        #expect(AttentionSettings().style == .steady)
    }

    @Test func animatedStylesStayAvailable() {
        #expect(AttentionStyle.allCases.contains(.blink))
        #expect(AttentionStyle.allCases.contains(.pulse))
    }
}
