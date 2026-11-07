import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo 2026-11-05: "the horizontal tab ... it's like a yellow bright dot, which I kind of like a little
/// bit more than the sidebar. What if we try that yellow dot thing that we currently have in the
/// horizontal tab and put that in the sidebar?" Needs input is one dot: the theme's yellow
/// (`ThemeTokens.attention`) at 3:1 on the rows, read by the sidebar's status colors and the tab
/// strip alike, never the old `systemOrange`.
@MainActor @Suite(.serialized) struct NeedsInputDotTests {
    static let ghosttyPalette: [ThemeRGB] = [0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6]
        .map { ThemeRGB(hex: $0) }
    static let dark = ThemeInput(background: ThemeRGB(hex: 0x1D1F21), foreground: ThemeRGB(hex: 0xC5C8C6), palette: ghosttyPalette)
    static let light = ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F), palette: ghosttyPalette)

    @Test(arguments: [true, false])
    func theDotIsTheThemesYellowAtThreeToOne(_ isDark: Bool) {
        let tokens = ThemeTokens.derive(from: isDark ? Self.dark : Self.light)
        let dot = tokens.statusDot(.attention)
        let row = tokens.windowBackground.withAlpha(1)
        for surface in [row, tokens.selectionFill.composited(over: row), tokens.pressedFill.composited(over: row)] {
            #expect(dot.contrast(with: surface) >= ThemeTokens.minimumMarkContrast, "\(isDark ? "dark" : "light"): under 3:1")
        }
        // The theme's yellow, moved only in lightness: never the system orange the sidebar drew.
        let orange = isDark ? ThemeRGB(r: 255, g: 159, b: 10) : ThemeRGB(r: 255, g: 149, b: 0)
        #expect(dot != orange)
        let hue = NSColor(srgbRed: dot.red, green: dot.green, blue: dot.blue, alpha: 1).hueComponent
        let theme = tokens.attention
        let themeHue = NSColor(srgbRed: theme.red, green: theme.green, blue: theme.blue, alpha: 1).hueComponent
        #expect(abs(hue - themeHue) < 0.03, "keeps the theme yellow's hue")
        if isDark { #expect(dot == tokens.attention.withAlpha(1), "a dark theme's yellow already reads: the tab's dot, unchanged") }
    }

    @Test(arguments: [true, false])
    func tabStripAndSidebarResolveOneColor(_ isDark: Bool) throws {
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Needs Input Dot")), input: isDark ? Self.dark : Self.light, animated: false)
        scope.perform {
            let tab = StatusIndicatorLayer.Colors.current(loading: nil).attention
            let sidebar = StatusIndicatorLayer.Colors.status(loading: nil).attention
            #expect(tab == sidebar)
            #expect(tab == Palette.statusAttention.cgColor)
            #expect(Palette.statusAttention.cgColor == scope.tokens.statusDot(.attention).nsColor.cgColor)
        }
    }
}
