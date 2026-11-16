@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The browser toolbar's glyphs read the one shared side (`DensityTokens.toolbarGlyphSize`): back,
/// forward, reload, the Extensions puzzle and the pinned buttons through `toolbarIconSize`, so the
/// pack's one ink box is one size on screen at every density. The bookmark star draws at it too,
/// clamped to its button in the bar.
@Suite struct ToolbarGlyphTokenTests {
    @Test func toolbarIconsReadTheSharedGlyphSide() {
        for preset in DensityPreset.allCases {
            let metrics = OmnibarMetrics(tokens: preset.tokens)
            #expect(metrics.toolbarIconSize == preset.tokens.toolbarGlyphSize, "\(preset)")
            let star = metrics.starIconSize
            #expect(star <= metrics.toolbarIconSize && star <= metrics.trailingIconSize + 2,
                    "\(preset): the star (\(star)) draws at the toolbar glyph side, within its button")
        }
    }

    /// A short bar shrinks the star's button (`trailingIconSize + 2`); the star never draws past it.
    @Test func theStarNeverOutgrowsItsButton() {
        for preset in DensityPreset.allCases {
            for height in stride(from: OmnibarMetrics.heightRange.lowerBound, through: OmnibarMetrics.heightRange.upperBound, by: 1) {
                let metrics = OmnibarMetrics(tokens: preset.tokens, height: height, fontSize: OmnibarMetrics.fontSizeRange.lowerBound)
                #expect(metrics.starIconSize <= metrics.trailingIconSize + 2, "\(preset) at \(height) pt")
            }
        }
    }
}
