import CmuxNextDesignTokens
import Testing

/// The window a new install gets (Leo, 2026-11-05: "new install should default to glass"): with
/// nothing set in cmux.json and the Ghostty config at Ghostty's own defaults (opacity 1, no blur),
/// the window resolves to Glass at the default opacity. Anything set in either config keeps its window.
@Suite struct WindowBackgroundDefaultTests {
    @Test func nothingSetAnywhereIsGlass() {
        let resolved = WindowBackgroundOverride().resolved(backgroundOpacity: 1, backgroundBlur: 0)
        #expect(resolved.backgroundOpacity == WindowBackgroundOverride.defaultTranslucentOpacity)
        #expect(resolved.backgroundBlur == -1)
    }

    @Test func aGhosttyConfigsOwnTranslucencyOrBlurIsKept() {
        let override = WindowBackgroundOverride()
        #expect(override.resolved(backgroundOpacity: 0.9, backgroundBlur: 0) == (0.9, 0))
        #expect(override.resolved(backgroundOpacity: 1, backgroundBlur: 20) == (1, 20))
        #expect(override.resolved(backgroundOpacity: 0.7, backgroundBlur: -2) == (0.7, -2))
    }

    @Test func noneAtFullOpacityInCmuxJSONIsOpaque() {
        let resolved = WindowBackgroundOverride(opacity: 1, material: .unblurred)
            .resolved(backgroundOpacity: 1, backgroundBlur: 0)
        #expect(resolved == (1, 0))
    }

    @Test func aChosenOpacityOrMaterialAppliesOverTheDefault() {
        #expect(WindowBackgroundOverride(opacity: 0.5, material: .frosted).resolved(backgroundOpacity: 1, backgroundBlur: 0).backgroundOpacity == 0.5)
        #expect(WindowBackgroundOverride(material: .frosted).resolved(backgroundOpacity: 1, backgroundBlur: 0).backgroundBlur > 0)
    }
}
