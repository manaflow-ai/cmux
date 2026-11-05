import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The Markdown viewer paints `--cmux-reading-background`. Over a background picture it is clear,
/// so the page shows the App Theme's one veil like the terminals and the sidebar (user 2026-11-02:
/// "markdown bg is not transparent"). Where the desktop and other windows read through the window
/// (glass or a translucent theme with no picture, or Window Glass, whose picture is itself
/// see-through) it stays the page color made opaque, so no text from behind reads through the
/// document (user 2026-10-31, #30818). An opaque window paints it opaque too.
@MainActor @Suite(.serialized)
struct WebThemeReadingBackgroundTests {
    private static let opaque = ThemeInput(background: ThemeRGB(hex: 0xEFF1F5), foreground: ThemeRGB(hex: 0x4C4F69))
    private static let translucent = ThemeInput(background: ThemeRGB(hex: 0xEFF1F5), foreground: ThemeRGB(hex: 0x4C4F69),
                                                backgroundOpacity: 0.6, backgroundBlur: 20)
    private static let windowGlass = ThemeInput(background: ThemeRGB(hex: 0xEFF1F5), foreground: ThemeRGB(hex: 0x4C4F69),
                                                backgroundOpacity: 0.6, backgroundBlur: -2)

    private static func reading(_ input: ThemeInput, picture: Bool) throws -> String {
        let scope = ThemeScope(level: .workspace)
        scope.pinBackdrop(picture ? .selection(.art(.friedrichForestMoonlight)) : .none)
        let tokens = ThemeTokens.derive(from: input)
        let theme = scope.perform { WebTheme(tokens, surface: .internalPage, backgrounds: .none) }
        return try #require(theme.variables["--cmux-reading-background"])
    }

    private static func page(_ input: ThemeInput, alpha: Double) -> String {
        WebTheme.css(ThemeTokens.derive(from: input).surfaceBackground.withAlpha(alpha))
    }

    @Test func overAPictureTheReadingPageIsClear() throws {
        #expect(try Self.reading(Self.opaque, picture: true) == Self.page(Self.opaque, alpha: 0))
        #expect(try Self.reading(Self.translucent, picture: true) == Self.page(Self.translucent, alpha: 0))
    }

    @Test func whereTheDesktopReadsThroughItStaysOpaque() throws {
        #expect(try Self.reading(Self.translucent, picture: false) == Self.page(Self.translucent, alpha: 1))
        #expect(try Self.reading(Self.windowGlass, picture: true) == Self.page(Self.windowGlass, alpha: 1))
        #expect(try Self.reading(Self.opaque, picture: false) == Self.page(Self.opaque, alpha: 1))
    }
}
