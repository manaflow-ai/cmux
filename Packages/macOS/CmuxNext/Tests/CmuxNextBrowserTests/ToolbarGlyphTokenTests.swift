@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The browser toolbar's glyphs read the one shared side (`DensityTokens.toolbarGlyphSize`): back,
/// forward, reload and the pinned buttons through `toolbarIconSize`, so the pack's one ink box is one
/// size on screen at every density. The Extensions puzzle and the bookmark star draw at their own
/// sides (16 and 12 pt of ink at Compact, Lucas 2026-11-18: `OmnibarTrailingGlyphsTests`), the star's
/// ink inside its plate in the bar.
@Suite struct ToolbarGlyphTokenTests {
    @Test func toolbarIconsReadTheSharedGlyphSide() {
        for preset in DensityPreset.allCases {
            let metrics = OmnibarMetrics(tokens: preset.tokens)
            #expect(metrics.toolbarIconSize == preset.tokens.toolbarGlyphSize, "\(preset)")
            let star = metrics.starIconSize
            #expect(star * OmnibarMetrics.starInkRatio <= metrics.starPlateSize,
                    "\(preset): the star's ink (\(star) pt side) stays within its button")
            #expect(metrics.extensionsIconSize <= metrics.buttonSize, "\(preset): the puzzle fits its button")
        }
    }

    /// A short bar shrinks the star's plate (`starPlateSize`); the star's ink never draws past it.
    @Test func theStarNeverOutgrowsItsButton() {
        for preset in DensityPreset.allCases {
            for height in stride(from: OmnibarMetrics.heightRange.lowerBound, through: OmnibarMetrics.heightRange.upperBound, by: 1) {
                let metrics = OmnibarMetrics(tokens: preset.tokens, height: height, fontSize: OmnibarMetrics.fontSizeRange.lowerBound)
                #expect(metrics.starIconSize * OmnibarMetrics.starInkRatio <= metrics.starPlateSize + 0.001, "\(preset) at \(height) pt")
            }
        }
    }
}
