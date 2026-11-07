@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The browser toolbar's glyphs read the one shared side (`DensityTokens.toolbarGlyphSize`): back,
/// forward, reload, the Extensions puzzle and the pinned buttons through `toolbarIconSize`, and the
/// bookmark star draws at it too, so the pack's one ink box is one size on screen at every density.
@Suite struct ToolbarGlyphTokenTests {
    @Test func toolbarIconsReadTheSharedGlyphSide() {
        for preset in DensityPreset.allCases {
            let metrics = OmnibarMetrics(tokens: preset.tokens)
            #expect(metrics.toolbarIconSize == preset.tokens.toolbarGlyphSize, "\(preset)")
        }
    }
}
