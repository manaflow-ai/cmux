@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// The page sizing token must receive the host's complete page zoom, including Agent Chat Zoom.
@MainActor @Suite struct InterfaceScaleScriptTests {
    @Test func scriptPublishesTheEffectivePageZoomAndNotOnlyUIScale() {
        let design = DesignSettings()
        design.uiScale = 1.25
        let script = design.interfaceScaleScript(pageZoom: 1.5625)

        #expect(script.contains("--cmux-ui-scale', '1.5625"))
        #expect(script.contains("cmux-ui-scale-change"))
    }

    @Test func omittedPageZoomUsesUIScale() {
        let design = DesignSettings()
        design.uiScale = 1.25

        #expect(design.interfaceScaleScript().contains("--cmux-ui-scale', '1.25"))
    }

    /// Pages follow Density: they are drawn for Default's 13 pt, grow with a larger chrome body
    /// size, never shrink below it (Compact keeps today's pages), and Text Size wins.
    @Test func pageTextScaleFollowsDensityAndTextSize() {
        let design = DesignSettings.shared
        let savedTokens = design.densityTokens, savedText = design.overrides[.chromeFontSize]
        defer {
            design.densityTokens = savedTokens
            design.setOverride(.chromeFontSize, savedText)
        }
        design.setOverride(.chromeFontSize, nil)
        design.densityTokens = DensityPreset.compact.tokens
        #expect(Typography.pageScale == 1)
        design.densityTokens = DensityPreset.cozy.tokens
        #expect(Typography.pageScale == 1)
        design.densityTokens = DensityPreset.spacious.tokens
        #expect(abs(Typography.pageScale - DensityPreset.spacious.tokens.bodySize / CGFloat(13)) < 0.0001)
        #expect(Typography.pageScale > 1)
        #expect(design.interfaceScaleScript().contains("--cmux-interface-scale', '\(Typography.pageScale)'"))
        design.setOverride(.chromeFontSize, 15)
        #expect(abs(Typography.pageScale - CGFloat(15) / CGFloat(13)) < 0.0001)
        design.setOverride(.chromeFontSize, 11)
        #expect(Typography.pageScale == 1)
    }

    /// The density tokens go both ways: Compact and Ultra-compact draw a page's density-following
    /// chrome (the composer) smaller than Default, where `pageScale` stays 1, and Spacious larger.
    @Test func pageDensityScalesShrinkBelowDefault() {
        let design = DesignSettings.shared
        let savedTokens = design.densityTokens, savedText = design.overrides[.chromeFontSize]
        defer {
            design.densityTokens = savedTokens
            design.setOverride(.chromeFontSize, savedText)
        }
        design.setOverride(.chromeFontSize, nil)
        var sizes: [CGFloat] = [], texts: [CGFloat] = []
        for preset in [DensityPreset.ultraCompact, .compact, .cozy, .comfortable, .spacious] {
            design.densityTokens = preset.tokens
            sizes.append(Typography.pageDensityScale)
            texts.append(Typography.pageDensityTextScale)
        }
        #expect(sizes[2] == 1)
        #expect(texts[2] == 1)
        #expect(sizes == sizes.sorted() && Set(sizes).count == sizes.count)
        #expect(texts == texts.sorted() && Set(texts).count == texts.count)
        #expect(sizes[1] < 1 && texts[1] < 1)
        design.densityTokens = DensityPreset.compact.tokens
        let script = design.interfaceScaleScript()
        #expect(script.contains("--cmux-density-scale', '\(Typography.pageDensityScale)'"))
        #expect(script.contains("--cmux-density-text-scale', '\(Typography.pageDensityTextScale)'"))
        design.setOverride(.chromeFontSize, 15)
        #expect(abs(Typography.pageDensityTextScale - CGFloat(15) / CGFloat(13)) < 0.0001)
    }
}
