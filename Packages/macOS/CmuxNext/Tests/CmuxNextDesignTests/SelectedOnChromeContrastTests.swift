import CmuxTheme
import Testing

/// A selected item in the content's surface reads only where it stands out of its chrome
/// (design/selected-is-foreground.md; Codex at 922f9ad0, F2): black shade over a near-black content
/// (Builtin Dark's #000000) or no shade at all keeps the selection fill.
@Suite struct SelectedOnChromeContrastTests {
    @Test func theDefaultShadesKeepTheContentSurface() {
        #expect(ThemeTokens.selectedOnChrome(.white, chromeShade: 0.045) == .white)
        let dark = ThemeRGB(red: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
        #expect(ThemeTokens.selectedOnChrome(dark, chromeShade: 0.28) == dark)
    }

    @Test func blackOnBlackFallsBack() {
        #expect(ThemeTokens.selectedOnChrome(.black, chromeShade: 0.28) == nil)
        #expect(ThemeTokens.selectedOnChrome(.black, chromeShade: 0.8) == nil)
    }

    @Test func noShadeOrASeeThroughContentFallsBack() {
        #expect(ThemeTokens.selectedOnChrome(.white, chromeShade: 0) == nil)
        #expect(ThemeTokens.selectedOnChrome(ThemeRGB.white.withAlpha(0.6), chromeShade: 0.045) == nil)
    }
}
