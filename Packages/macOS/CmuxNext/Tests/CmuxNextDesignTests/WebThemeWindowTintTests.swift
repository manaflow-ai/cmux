import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// A see-through page cannot see the tint the window lays natively over a picture or the desktop, so
/// its text selection measured surfaces over black and a selection the color of a chat bubble passed
/// (Monokai Classic at Opacity 0.85, user 2026-11-15). WebTheme sends that tint as
/// `--cmux-window-tint` (webviews ui/highlightContrast.ts `pageCanvases`): the window's color at the
/// tint opacity the window paints.
struct WebThemeWindowTintTests {
    @Test @MainActor func aTranslucentWindowSendsItsTint() throws {
        let tokens = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x272822),
                                                         foreground: ThemeRGB(hex: 0xFDFFF1),
                                                         backgroundOpacity: 0.85))
        let tint = try #require(WebTheme(tokens, backgrounds: .none).variables["--cmux-window-tint"])
        #expect(tint == WebTheme.css(tokens.windowBackground.withAlpha(WindowBackdrop.currentTint(tokens))))
    }
}
