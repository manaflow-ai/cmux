import CMUXMobileCore
import CmuxTheme
import Testing
import CmuxNextDesign

/// A phone renders a `TerminalTheme`; its chrome must match the Mac's for the
/// same colors.
@Suite struct TerminalThemeInputTests {
    @Test func monokaiReadsTheSameColorsAsTheMac() {
        let input = ThemeInput(terminalTheme: .monokai)
        #expect(input.background == ThemeRGB(hex: 0x272822))
        #expect(input.foreground == ThemeRGB(hex: 0xFDFFF1))
        #expect(input.palette.count == 16)
        #expect(input.palette[1] == ThemeRGB(hex: 0xF92672))
        #expect(input.selectionBackground == ThemeRGB(hex: 0x57584F))
        #expect(input.selectionForeground == ThemeRGB(hex: 0xFDFFF1))
    }

    // A cell-relative selection has no fixed color, so the tokens use their
    // own selection fill.
    @Test func aCellRelativeSelectionIsLeftToTheTokens() {
        var theme = TerminalTheme.monokai
        theme.selectionBackgroundSemantic = .foreground
        theme.selectionForegroundSemantic = .background
        let input = ThemeInput(terminalTheme: theme)
        #expect(input.selectionBackground == nil)
        #expect(input.selectionForeground == nil)
    }

    @Test func opacityAndBlurPassThrough() {
        let input = ThemeInput(terminalTheme: .monokai, backgroundOpacity: 0.8, backgroundBlur: 20)
        #expect(input.backgroundOpacity == 0.8)
        #expect(input.backgroundBlur == 20)
    }

    // The phone renders an invalid theme as Monokai (`validatedOrDefault()`),
    // so its chrome must derive from Monokai too: never shift the palette
    // past a bad entry, or mix the theme's colors with a fallback's.
    @Test func anInvalidThemeReadsAsTheThemeThePhoneRenders() {
        var theme = TerminalTheme.monokai
        theme.background = "#1e1e2e"
        theme.palette[0] = "not a color"
        #expect(!theme.isValid)
        #expect(ThemeInput(terminalTheme: theme) == ThemeInput(terminalTheme: theme.validatedOrDefault()))
    }
}
