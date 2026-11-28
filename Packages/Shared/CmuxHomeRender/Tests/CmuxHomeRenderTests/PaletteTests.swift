import CoreGraphics
import Testing
@testable import CmuxHomeRender

/// The palette comes from the theme: the sent bubble and the caret use the
/// theme's accent, nothing is blue unless the theme says so.
@MainActor
@Suite struct PaletteTests {
    @Test func accentDrivesSentBubbleAndCaret() throws {
        let p = HomePalette.themed(Fixtures.theme)
        #expect(p.caret == Fixtures.theme.accent)
        #expect(p.outgoingGradient.first?.color == Fixtures.theme.accent)
        let bottom = try #require(p.outgoingGradient.last?.color)
        #expect(bottom.green < Fixtures.theme.accent.green, "sent bubbles darken toward the bottom of the viewport")
        #expect(p.outgoingGradient.allSatisfy { $0.color.blue <= $0.color.green }, "a green accent gives no blue bubble")
    }

    @Test func aBlueAccentIsTheUsersChoice() {
        var theme = Fixtures.theme
        theme.accent = .rgb255(43, 141, 253)
        let p = HomePalette.themed(theme)
        #expect(p.caret == theme.accent)
        #expect(p.outgoingText == .gray255(255))
    }

    @Test func lightAccentGetsDarkText() {
        var theme = Fixtures.theme
        theme.accent = .rgb255(240, 230, 120)
        #expect(HomePalette.themed(theme).outgoingText == .gray255(0))
    }

    @Test func inactiveWindowMutesTheAccent() {
        let active = HomePalette.themed(Fixtures.theme)
        let inactive = HomePalette.themed(Fixtures.theme, active: false)
        #expect(inactive.outgoingGradient.first?.color != active.outgoingGradient.first?.color)
        #expect(inactive.caret == active.caret)
    }
}
