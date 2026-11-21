import CoreGraphics
import Testing
@testable import CmuxHomeRender

/// The Chief composer's placeholder over a see-through window. Its field is clear glass over art
/// or the desktop there, and the field-tier ink (`placeholder`, 4.5:1 on the opaque field colour)
/// fell to 1.84:1 on the Great Wave in light and 2.22:1 in dark (fleet capture of d65e0292,
/// text-inputs-glass/states.py, chief-art). The web composer and every web field take the
/// secondary tier there (composerStates.css, ui/controls.css), so native and web match: over a
/// see-through fill the placeholder is the secondary text. An opaque fill keeps the field tier.
@Suite struct SeeThroughPlaceholderTests {
    nonisolated static let themes: [HomePalette.Theme] = [
        .init(background: .gray255(255), foreground: .gray255(29), accent: .rgb255(2, 132, 254), failure: .rgb255(215, 0, 21)),
        .init(background: .gray255(30), foreground: .gray255(230), accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58)),
    ]

    @Test(arguments: themes)
    func seeThroughFillTakesTheSecondaryTier(_ theme: HomePalette.Theme) {
        let palette = HomePalette.themed(theme).onBackground(theme.background.with(alpha: 0), over: theme.background)
        #expect(palette.placeholder == palette.secondaryText)
    }

    @Test(arguments: themes)
    func opaqueFillKeepsTheFieldTier(_ theme: HomePalette.Theme) {
        let base = HomePalette.themed(theme)
        let palette = base.onBackground(theme.background, over: theme.background)
        #expect(palette.placeholder == base.placeholder)
    }
}
