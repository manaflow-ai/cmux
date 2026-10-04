import AppKit
import Testing
@testable import CmuxNextDesign

/// Chrome colors derive from the terminal theme: surfaces are its
/// background, fills its foreground at low alpha, text meets WCAG contrast.
@Suite struct ThemeTokensTests {
    @Test(arguments: ThemeFixtures.all.map(\.0))
    func surfacesAreTheTerminalBackground(_ name: String) {
        let input = theme(name)
        let t = ThemeTokens.derive(from: input)
        #expect(t.windowBackground == input.background)
        #expect(t.sidebarBackground == input.background)
        #expect(t.contentBackground == input.background)
    }

    /// Tab strips share the window ground; hierarchy comes from fills.
    @Test(arguments: ThemeFixtures.all.map(\.0))
    func theStripMatchesTheWindow(_ name: String) {
        let t = ThemeTokens.derive(from: theme(name))
        #expect(t.stripBackground == t.windowBackground, "\(name)")
        #expect(t.textPrimary.contrast(with: t.stripBackground.withAlpha(1)) >= 4.5, "\(name)")
        // Inactive tab titles use the muted text styles.
        #expect(t.textSecondary.contrast(with: t.stripBackground.withAlpha(1)) >= 4.5, "\(name) secondary")
        #expect(t.textTertiary.contrast(with: t.stripBackground.withAlpha(1)) >= 3.0, "\(name) tertiary")
    }

    /// Only the sidebar retains a tonal step; strips add none.
    @Test(arguments: ThemeFixtures.all.map(\.0))
    func theStepsCompositeToTheChromeSurfaces(_ name: String) {
        let input = theme(name)
        let t = ThemeTokens.derive(from: input)
        let bg = input.background.withAlpha(1)
        func close(_ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
            abs(a.red - b.red) < 0.002 && abs(a.green - b.green) < 0.002 && abs(a.blue - b.blue) < 0.002
        }
        #expect(t.stripStep.alpha == 0 && t.sidebarStep.alpha < 1, "\(name)")
        #expect(close(t.sidebarStep.composited(over: bg), bg.mixed(toward: input.foreground, 0.04)), "\(name) sidebar")
    }

    @Test func lightnessFollowsTheBackground() {
        #expect(ThemeTokens.derive(from: ThemeFixtures.monokaiClassic).isDark)
        #expect(ThemeTokens.derive(from: ThemeFixtures.catppuccinMocha).isDark)
        #expect(ThemeTokens.derive(from: ThemeFixtures.gruvboxDark).isDark)
        #expect(!ThemeTokens.derive(from: ThemeFixtures.githubLight).isDark)
    }

    @Test func readableThemesKeepTheirForeground() {
        for input in [ThemeFixtures.monokaiClassic, ThemeFixtures.catppuccinMocha, ThemeFixtures.gruvboxDark, ThemeFixtures.githubLight] {
            #expect(ThemeTokens.derive(from: input).textPrimary == input.foreground)
        }
    }

    /// WCAG AA (4.5:1) for primary and secondary text, 3:1 for tertiary text
    /// and status marks, on the bare surface and on every fill a row can have.
    @Test(arguments: ThemeFixtures.all.map(\.0))
    func textMeetsContrastOnEveryFill(_ name: String) {
        let input = theme(name)
        let t = ThemeTokens.derive(from: input)
        let bg = input.background
        let surfaces = [bg, t.hoverFill.composited(over: bg), t.selectionFill.composited(over: bg),
                        t.secondarySelectionFill.composited(over: bg), t.pressedFill.composited(over: bg), t.chromeBackground]
        for surface in surfaces {
            #expect(t.textPrimary.contrast(with: surface) >= 4.5, "\(name) primary on \(surface)")
            #expect(t.textSecondary.contrast(with: surface) >= 4.5, "\(name) secondary on \(surface)")
            #expect(t.textTertiary.contrast(with: surface) >= 3.0, "\(name) tertiary on \(surface)")
        }
        for mark in [t.attention, t.danger, t.success, t.highlight] {
            #expect(mark.contrast(with: bg) >= 3.0, "\(name) status \(mark)")
        }
        #expect(t.highlightText.contrast(with: t.highlight) >= 4.5, "\(name) text on highlight")
    }

    @Test(arguments: ThemeFixtures.all.map(\.0))
    func hierarchyIsMutedForegroundNotANewHue(_ name: String) {
        let input = theme(name)
        let t = ThemeTokens.derive(from: input)
        // Fills are the foreground itself at rising alpha.
        for fill in [t.hoverFill, t.selectionFill, t.pressedFill, t.separator, t.badgeFill] {
            #expect(fill.withAlpha(1) == t.textPrimary.withAlpha(1) || fill.withAlpha(1) == input.foreground)
        }
        #expect(t.hoverFill.alpha < t.selectionFill.alpha)
        #expect(t.selectionFill.alpha < t.pressedFill.alpha)
        #expect(t.separator.alpha <= 0.08)
        // Lifted surfaces sit between background and foreground.
        for lifted in [t.chromeBackground, t.elevatedBackground] {
            #expect(between(lifted, input.background, input.foreground))
        }
    }

    @Test func secondaryTextIsQuieterThanPrimaryWhenContrastAllows() {
        for input in [ThemeFixtures.monokaiClassic, ThemeFixtures.catppuccinMocha, ThemeFixtures.gruvboxDark, ThemeFixtures.githubLight] {
            let t = ThemeTokens.derive(from: input)
            #expect(t.textSecondary.contrast(with: input.background) < t.textPrimary.contrast(with: input.background))
            #expect(t.textTertiary.contrast(with: input.background) <= t.textSecondary.contrast(with: input.background))
        }
    }

    @Test func statusColorsComeFromTheAnsiPalette() {
        let t = ThemeTokens.derive(from: ThemeFixtures.gruvboxDark)
        // Gruvbox's red is too dark on its background: lifted, still red.
        #expect(t.danger.contrast(with: ThemeRGB(hex: 0x282828)) >= 3)
        #expect(t.danger.red > t.danger.green && t.danger.red > t.danger.blue)
        #expect(ThemeTokens.derive(from: ThemeFixtures.catppuccinMocha).attention == ThemeRGB(hex: 0xF9E2AF))
        #expect(ThemeTokens.derive(from: ThemeFixtures.githubLight).success == ThemeRGB(hex: 0x116329))
        let mocha = ThemeTokens.derive(from: ThemeFixtures.catppuccinMocha)
        #expect(mocha.highlight == ThemeRGB(hex: 0x89B4FA))
        #expect(mocha.highlightText == ThemeRGB(hex: 0x1E1E2E))
    }

    @Test func translucentBackgroundCarriesItsOpacity() {
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = 0.85
        let t = ThemeTokens.derive(from: input)
        #expect(t.windowBackground.alpha == 0.85)
        #expect(t.backgroundOpacity == 0.85)
        #expect(t.chromeBackground.alpha == 1)
    }

    @Test func explicitSurfaceOverridesAreOptInAndIndependent() {
        let base = ThemeTokens.derive(from: ThemeFixtures.catppuccinMocha)
        let terminal = ThemeRGB(cssHex: "#10203080")!
        let sidebar = ThemeRGB(cssHex: "#304050")!
        let result = base.applying(SurfaceBackgroundOverrides(sidebar: sidebar, terminal: terminal))
        #expect(result.windowBackground == terminal)
        #expect(result.sidebarBackground == sidebar)
        #expect(result.stripBackground == base.surfaceBackground)
        #expect(result.contentBackground == terminal)
    }

    @Test func contrastMathMatchesWCAG() {
        #expect(abs(ThemeRGB.black.contrast(with: .white) - 21) < 0.01)
        #expect(abs(ThemeRGB(hex: 0x777777).contrast(with: .white) - 4.48) < 0.02)
    }

    private func theme(_ name: String) -> ThemeInput {
        ThemeFixtures.all.first { $0.0 == name }!.1
    }

    private func between(_ c: ThemeRGB, _ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
        func inRange(_ x: Double, _ lo: Double, _ hi: Double) -> Bool { x >= min(lo, hi) - 1e-9 && x <= max(lo, hi) + 1e-9 }
        return inRange(c.red, a.red, b.red) && inRange(c.green, a.green, b.green) && inRange(c.blue, a.blue, b.blue)
    }
}
