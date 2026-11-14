@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import JavaScriptCore
import Testing

/// The page sizing token must receive the host's complete page zoom, including Agent Chat Zoom.
@MainActor @Suite struct InterfaceScaleScriptTests {
    @Test func aQueuedScalePushKeepsTheZoomTheRendererActuallyShows() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var values = {};
        var document = { documentElement: { style: { setProperty: (key, value) => values[key] = String(value) } } };
        var window = {
          devicePixelRatio: 2,
          dispatchEvent: () => {},
          __cmuxSyncPageZoom: () => document.documentElement.style.setProperty('--cmux-ui-scale', window.devicePixelRatio / 2)
        };
        function Event(name) { this.type = name; }
        """)
        let design = DesignSettings()
        // The host requests 150%, but Chromium still draws 100% while its zoom IPC is pending.
        context.evaluateScript(design.interfaceScaleScript(pageZoom: 1.5))
        #expect(context.exception == nil)
        #expect(context.evaluateScript("values['--cmux-ui-scale']").toString() == "1")
        // A queued older push must not change column sizing after Chromium reaches 150%.
        context.evaluateScript("window.devicePixelRatio = 3")
        context.evaluateScript(design.interfaceScaleScript(pageZoom: 1.1))
        #expect(context.evaluateScript("values['--cmux-ui-scale']").toString() == "1.5")
    }

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
        // Over Default's 14 pt body (the ChatGPT app's, Lucas 2026-11-13).
        #expect(abs(Typography.pageScale - DensityPreset.spacious.tokens.bodySize / DensityPreset.cozy.tokens.bodySize) < 0.0001)
        #expect(Typography.pageScale > 1)
        #expect(design.interfaceScaleScript().contains("--cmux-interface-scale', '\(Typography.pageScale)'"))
        design.setOverride(.chromeFontSize, 15)
        #expect(abs(Typography.pageScale - CGFloat(15) / DensityPreset.cozy.tokens.bodySize) < 0.0001)
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
        // Ultra-compact and Compact share their 20 pt rows; Default and Comfortable share 14 pt text (Lucas 2026-11-13).
        #expect(sizes == sizes.sorted() && sizes[0] < sizes[2] && sizes[2] < sizes[4])
        #expect(texts == texts.sorted() && texts[0] < texts[1] && texts[1] < texts[2] && texts[3] < texts[4])
        #expect(sizes[1] < 1 && texts[1] < 1)
        design.densityTokens = DensityPreset.compact.tokens
        let script = design.interfaceScaleScript()
        #expect(script.contains("--cmux-density-scale', '\(Typography.pageDensityScale)'"))
        #expect(script.contains("--cmux-density-text-scale', '\(Typography.pageDensityTextScale)'"))
        design.setOverride(.chromeFontSize, 15)
        #expect(abs(Typography.pageDensityTextScale - CGFloat(15) / DensityPreset.cozy.tokens.bodySize) < 0.0001)
    }
}
