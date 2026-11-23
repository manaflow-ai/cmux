import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The split divider override (`appearance.surfaces.splitDivider`) colors the sidebar's edge line and every split's
/// line. Resolved as a backdrop, an opacity alone painted the window's background color, so the lines vanished (Leo,
/// 2026-11-19: "why is there no divider showing between my sidebar and the rest of the stuff? and between pane
/// splits?"). It resolves as a line: its color, else the chrome divider's, at its opacity.
struct SplitDividerLineTests {
    private let base = ThemeRGB(red: 1, green: 1, blue: 1, alpha: 0.18)
    private let input = ThemeInput(background: ThemeRGB(hex: 0x101820), foreground: ThemeRGB(hex: 0xE8E8F0),
                                   backgroundOpacity: 0.6)

    @Test func noOverrideIsNoLineOverride() {
        #expect(SurfaceBackgrounds.none.dividerLine(base: base) == nil)
    }

    @Test func anOpacityAloneKeepsTheDividersColor() throws {
        let own = SurfaceBackgrounds(overrides: [.splitDivider: SurfaceBackground(opacity: 0.5)])
        let line = try #require(own.dividerLine(base: base))
        #expect(line == base.withAlpha(0.5))
        // As a backdrop the same override was the window's background color: an invisible line.
        let tokens = ThemeTokens.derive(from: input)
        #expect(own.fill(for: .splitDivider, tokens: tokens).map { $0.withAlpha(1) } != line.withAlpha(1))
    }

    @Test func aColorKeepsItsOwnAlphaUnlessAnOpacityIsSet() throws {
        let red = ThemeRGB(red: 1, green: 0, blue: 0, alpha: 0.8)
        let color = SurfaceBackgrounds(overrides: [.splitDivider: SurfaceBackground(color: red)])
        #expect(color.dividerLine(base: base) == red)
        let both = SurfaceBackgrounds(overrides: [.splitDivider: SurfaceBackground(color: red, opacity: 0.5)])
        #expect(both.dividerLine(base: base) == red.withAlpha(0.4))
    }

    @Test @MainActor func pagesDrawTheLineNotTheBackground() throws {
        let tokens = ThemeTokens.derive(from: input)
        let own = SurfaceBackgrounds(overrides: [.splitDivider: SurfaceBackground(opacity: 1)])
        let divider = WebTheme.chromeDivider(tokens, backgrounds: own)
        #expect(divider != WebTheme.css(tokens.surfaceBackground.withAlpha(1)))
        #expect(divider != "transparent")
    }
}
