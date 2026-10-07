import AppKit
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// nxdog66 crashed (SIGABRT, an NSException in -[NSColorSpaceColor getWhite:alpha:]):
/// MessagesLab's Markdown palette read the bubble text colour's white component, which
/// AppKit allows only for a grey colour. A cmux theme gives sRGB colours, and an HDR
/// theme gives sRGB with headroom (components above 1). Every theme must draw.
@MainActor @Suite(.serialized) struct MarkdownColorTests {
    private func withTheme(_ theme: HomePalette.Theme, _ body: () -> Void) {
        Fixture.theme = FixtureTheme(active: .themed(theme), inactive: .themed(theme, active: false), measuredAccent: false)
        defer { Fixture.theme = nil }
        body()
    }

    @Test func aThemedBubbleBuildsItsMarkdownPalette() {
        let dark = HomePalette.Theme(background: HomeColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 1),
                                     foreground: HomeColor(red: 0.8, green: 0.84, blue: 0.96, alpha: 1),
                                     accent: HomeColor(red: 0.54, green: 0.7, blue: 0.98, alpha: 1),
                                     failure: HomeColor(red: 0.95, green: 0.55, blue: 0.66, alpha: 1))
        withTheme(dark) {
            let incoming = MDPalette.make(outgoing: false), outgoing = MDPalette.make(outgoing: true)
            #expect(incoming.tokens.count == outgoing.tokens.count)
        }
    }

    @Test func anHDRThemeColourBuildsItsMarkdownPalette() {
        // Components above 1: an extended-range (HDR headroom) sRGB colour from the theme path.
        let hdr = HomePalette.Theme(background: HomeColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1),
                                    foreground: HomeColor(red: 1.4, green: 1.4, blue: 1.4, alpha: 1),
                                    accent: HomeColor(red: 0.2, green: 0.5, blue: 1.3, alpha: 1),
                                    failure: HomeColor(red: 1.2, green: 0.3, blue: 0.3, alpha: 1))
        withTheme(hdr) {
            let incoming = MDPalette.make(outgoing: false)
            #expect(!incoming.tokens.isEmpty)
        }
    }
}
