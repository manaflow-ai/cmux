@testable import CmuxNextDesign
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

    /// Pages follow Density: the text scale is the density's body size over Compact's, and a
    /// Text Size (`chromeFontSize`) wins over it.
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
        design.densityTokens = DensityPreset.spacious.tokens
        #expect(Typography.pageScale == DensityPreset.spacious.tokens.bodySize / DensityPreset.compact.tokens.bodySize)
        #expect(Typography.pageScale > 1)
        #expect(design.interfaceScaleScript().contains("--cmux-interface-scale', '\(Typography.pageScale)'"))
        design.setOverride(.chromeFontSize, 15)
        #expect(Typography.pageScale == 15 / DensityPreset.compact.tokens.bodySize)
    }
}
