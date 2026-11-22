import AppKit
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// A themed bubble's text colour is sRGB (`FixtureTheme`), and AppKit's
/// `getWhite(_:alpha:)` raises NSInvalidArgumentException for a colour
/// outside a grey space (UIKit returns false). On 2026-10-07 a themed
/// agent Markdown reply raised it inside the Home projection's main-actor
/// task at launch; AppKit swallowed the exception, and the unwound task
/// left the Swift runtime's executor tracking dangling, so the next main
/// actor check (MainThreadWatchdog's run-loop observer) crashed with
/// SIGBUS (g1ovl-v2, cmux-lawrence-2, 2 of 2 launches).
@MainActor @Suite(.serialized) struct MarkdownPaletteThemeTests {
    private func theme(background: HomeColor, foreground: HomeColor) -> FixtureTheme {
        let t = HomePalette.Theme(background: background, foreground: foreground,
                                  accent: HomeColor(red: 0, green: 0.48, blue: 1, alpha: 1),
                                  failure: HomeColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
        return FixtureTheme(active: .themed(t, active: true), inactive: .themed(t, active: false), measuredAccent: false)
    }

    @Test func aDarkThemesIncomingMarkdownUsesTheDarkSyntaxColours() {
        defer { Fixture.theme = nil }
        Fixture.theme = theme(background: .gray255(30), foreground: .gray255(230))
        let palette = MDPalette.make(outgoing: false)
        #expect(palette.tokens[.keyword] == Fixture.p3(255, 122, 178), "light text on a dark bubble")
    }

    @Test func aLightThemesIncomingMarkdownUsesTheLightSyntaxColours() {
        defer { Fixture.theme = nil }
        Fixture.theme = theme(background: .gray255(250), foreground: .gray255(20))
        let palette = MDPalette.make(outgoing: false)
        #expect(palette.tokens[.keyword] == Fixture.p3(155, 35, 147), "dark text on a light bubble")
    }

    @Test func aThemedOutgoingBubbleMakesItsPalette() {
        defer { Fixture.theme = nil }
        Fixture.theme = theme(background: .gray255(30), foreground: .gray255(230))
        let palette = MDPalette.make(outgoing: true)
        #expect(palette.text == Fixture.outgoingText)
    }
}
