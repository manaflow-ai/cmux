import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Pages cut rings around avatars and swatches, fill pills over rules and draw glyphs on filled
/// buttons in the page color (cx-wqn5). That color must be opaque: in a translucent window the
/// theme's surface carries `background-opacity`, so a ring let the rule show through, and a page
/// with its own background (`appearance.surfaces`) showed the theme's instead.
struct WebThemeSolidSurfaceTests {
    private let input = ThemeInput(background: ThemeRGB(hex: 0x101820), foreground: ThemeRGB(hex: 0xE8E8F0),
                                   backgroundOpacity: 0.6)

    @Test @MainActor func aTranslucentThemesPageColorIsOpaque() throws {
        let tokens = ThemeTokens.derive(from: input)
        #expect(tokens.surfaceBackground.alpha < 1)
        let solid = try #require(WebTheme(tokens, surface: .internalPage, backgrounds: .none).variables["--cmux-surface-solid"])
        #expect(solid == WebTheme.css(tokens.surfaceBackground.withAlpha(1)))
    }

    @Test @MainActor func aPagesOwnBackgroundIsItsSolidColor() throws {
        let tokens = ThemeTokens.derive(from: input)
        let own = SurfaceBackgrounds(overrides: [.internalPage: SurfaceBackground(color: ThemeRGB(hex: 0x402030), opacity: 1)])
        let solid = try #require(WebTheme(tokens, surface: .internalPage, backgrounds: own).variables["--cmux-surface-solid"])
        #expect(solid == WebTheme.css(ThemeRGB(hex: 0x402030)))
    }
}
