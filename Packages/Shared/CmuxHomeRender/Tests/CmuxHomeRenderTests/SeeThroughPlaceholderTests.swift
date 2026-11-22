import CoreGraphics
import Testing
@testable import CmuxHomeRender

/// The Chief composer's placeholder over a see-through window. Its field is clear glass over art
/// or the desktop there, and the field-tier ink (`placeholder`, 4.5:1 on the opaque field colour)
/// fell to 1.84:1 on the Great Wave in light and 2.22:1 in dark (fleet capture of d65e0292,
/// text-inputs-glass/states.py, chief-art), while every web field's placeholder there takes the
/// secondary text token (--cmux-text-secondary; ui/controls.css, composerStates.css). Over a
/// see-through fill the placeholder is the host's secondary token, so native and web match. An
/// opaque fill keeps the field tier.
@Suite struct SeeThroughPlaceholderTests {
    nonisolated static let themes: [HomePalette.Theme] = [
        .init(background: .gray255(255), foreground: .gray255(29), accent: .rgb255(2, 132, 254), failure: .rgb255(215, 0, 21)),
        .init(background: .gray255(30), foreground: .gray255(230), accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58)),
    ]
    /// The host's secondary text token (the web's --cmux-text-secondary).
    static let secondaryToken = HomeColor.gray255(128, alpha: 0.85)

    @Test(arguments: themes)
    func seeThroughFillTakesTheSecondaryToken(_ theme: HomePalette.Theme) {
        let palette = HomePalette.themed(theme).onBackground(theme.background.with(alpha: 0), over: theme.background,
                                                             placeholderOverGlass: Self.secondaryToken)
        #expect(palette.placeholder == Self.secondaryToken)
    }

    @Test(arguments: themes)
    func opaqueFillKeepsTheFieldTier(_ theme: HomePalette.Theme) {
        let base = HomePalette.themed(theme)
        let palette = base.onBackground(theme.background, over: theme.background, placeholderOverGlass: Self.secondaryToken)
        #expect(palette.placeholder == base.placeholder)
    }

    /// The token alone held 2.7:1 and 2.4:1 on art (be805d96): the clear field shows the picture under
    /// the text. Over a see-through fill the field takes the host's fill (the web composer's surface);
    /// an opaque fill keeps the clear glass.
    static let webSurface = HomeColor.gray255(240, alpha: 0.62)

    @Test(arguments: themes)
    func seeThroughFillGivesTheFieldTheWebSurface(_ theme: HomePalette.Theme) {
        let palette = HomePalette.themed(theme).onBackground(theme.background.with(alpha: 0), over: theme.background,
                                                             placeholderOverGlass: Self.secondaryToken, fieldFillOverGlass: Self.webSurface)
        #expect(palette.composeFillOverGlass == Self.webSurface)
    }

    @Test(arguments: themes)
    func opaqueFillKeepsTheClearField(_ theme: HomePalette.Theme) {
        let palette = HomePalette.themed(theme).onBackground(theme.background, over: theme.background,
                                                             placeholderOverGlass: Self.secondaryToken, fieldFillOverGlass: Self.webSurface)
        #expect(palette.composeFillOverGlass == nil)
    }
}
