import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Web pages draw the caret and selected text in the Ghostty config's colors (cx-wqn5): the
/// caret is the cursor color (else the text color), and selected text takes the config's
/// `selection-background` when it names one, else the accent tint pages used before.
struct WebThemeCaretSelectionTests {
    private let background = ThemeRGB(hex: 0x101018)
    private let foreground = ThemeRGB(hex: 0xE8E8F0)

    @Test @MainActor func theConfigsSelectionColorReachesPages() {
        let input = ThemeInput(background: background, foreground: foreground, selectionBackground: ThemeRGB(hex: 0x335577))
        let variables = WebTheme(ThemeTokens.derive(from: input)).variables
        #expect(variables["--cmux-text-selection"] == WebTheme.css(ThemeRGB(hex: 0x335577)))
    }

    @Test @MainActor func withoutOneSelectionKeepsTheAccentTint() {
        let variables = WebTheme(ThemeTokens.derive(from: ThemeInput(background: background, foreground: foreground))).variables
        #expect(variables["--cmux-text-selection"]?.contains("var(--cmux-accent") == true)
    }

    @Test @MainActor func theCaretDefaultsToTheTextColor() {
        let tokens = ThemeTokens.derive(from: ThemeInput(background: background, foreground: foreground))
        #expect(WebTheme(tokens).variables["--cmux-caret"] == WebTheme.css(tokens.textPrimary))
    }
}
