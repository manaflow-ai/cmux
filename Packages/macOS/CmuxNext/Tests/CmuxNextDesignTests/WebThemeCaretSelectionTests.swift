import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Web pages draw the caret and selected text in the Ghostty config's colors (cx-wqn5): the
/// caret is the cursor color (else the text color), and selected text takes the config's
/// `selection-background` when it names one, else the derived color text fields use.
struct WebThemeCaretSelectionTests {
    private let background = ThemeRGB(hex: 0x101018)
    private let foreground = ThemeRGB(hex: 0xE8E8F0)

    @Test @MainActor func theConfigsSelectionColorReachesPages() {
        let input = ThemeInput(background: background, foreground: foreground, selectionBackground: ThemeRGB(hex: 0x335577))
        let variables = WebTheme(ThemeTokens.derive(from: input)).variables
        #expect(variables["--cmux-text-selection"] == WebTheme.css(ThemeRGB(hex: 0x335577)))
    }

    /// Many themes select by inverse video (`selection-background` = the foreground, with a dark
    /// `selection-foreground`). Pages and fields draw only the fill, so that fill would hide the
    /// text: such a selection keeps the derived one, the same in pages and in text fields.
    @Test @MainActor func anInverseVideoSelectionKeepsTextReadable() {
        let input = ThemeInput(background: background, foreground: foreground,
                               selectionBackground: foreground, selectionForeground: background)
        let tokens = ThemeTokens.derive(from: input)
        #expect(WebTheme(tokens).variables["--cmux-text-selection"] == WebTheme.css(tokens.textSelection))
        #expect(tokens.textPrimary.contrast(with: tokens.textSelection.composited(over: background)) >= ThemeTokens.minimumMarkContrast)
    }

    /// One highlight app-wide (user 2026-10-28, "consistent"): without a config selection, pages
    /// select in the same color as native text fields and the omnibar (`Palette.textSelection`),
    /// not an accent tint of their own.
    @Test @MainActor func withoutOnePagesSelectLikeTextFields() {
        let tokens = ThemeTokens.derive(from: ThemeInput(background: background, foreground: foreground))
        #expect(WebTheme(tokens).variables["--cmux-text-selection"] == WebTheme.css(tokens.textSelection))
    }

    /// Code pages (diffs, Markdown code, the editor) take their selection from the terminal colors
    /// the host sends (`terminal.selectionBackground`), not a fixed blue of their own.
    @Test @MainActor func codePagesGetTheSameHighlight() {
        let configured = WebTheme(ThemeTokens.derive(from: ThemeInput(background: background, foreground: foreground,
                                                                      selectionBackground: ThemeRGB(hex: 0x335577))))
        #expect(configured.terminal.selectionBackground == "#335577")
        #expect(configured.terminal.json["selectionBackground"] as? String == "#335577")
        let derived = ThemeTokens.derive(from: ThemeInput(background: background, foreground: foreground))
        #expect(WebTheme(derived).terminal.selectionBackground == WebTheme.hex(derived.textSelection))
    }

    @Test @MainActor func theCaretDefaultsToTheTextColor() {
        let tokens = ThemeTokens.derive(from: ThemeInput(background: background, foreground: foreground))
        #expect(WebTheme(tokens).variables["--cmux-caret"] == WebTheme.css(tokens.textPrimary))
    }

    @Test @MainActor func theConfigsCursorColorIsTheCaret() {
        let input = ThemeInput(background: background, foreground: foreground, cursor: ThemeRGB(hex: 0xFF8800))
        #expect(WebTheme(ThemeTokens.derive(from: input)).variables["--cmux-caret"] == WebTheme.css(ThemeRGB(hex: 0xFF8800)))
    }
}
