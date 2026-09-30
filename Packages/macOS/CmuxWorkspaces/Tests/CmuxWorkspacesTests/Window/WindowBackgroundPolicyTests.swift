import Testing
import AppKit
@testable import CmuxWorkspaces

private struct StubSettings: WindowBackgroundSettingsReading {
    var sidebarBlendModeRawValue: String
    var isBackgroundGlassEnabled: Bool
}

@Suite struct WindowBackgroundPolicyTests {
    @Test func glassRequiresBehindWindowAndEnabled() {
        let policy = WindowBackgroundPolicy(
            settings: StubSettings(sidebarBlendModeRawValue: "withinWindow", isBackgroundGlassEnabled: false)
        )
        #expect(
            policy.shouldApplyWindowGlass(
                sidebarBlendMode: "behindWindow",
                bgGlassEnabled: true,
                glassEffectAvailable: false
            )
        )
        #expect(
            !policy.shouldApplyWindowGlass(
                sidebarBlendMode: "withinWindow",
                bgGlassEnabled: true,
                glassEffectAvailable: true
            )
        )
        #expect(
            !policy.shouldApplyWindowGlass(
                sidebarBlendMode: "behindWindow",
                bgGlassEnabled: false,
                glassEffectAvailable: true
            )
        )
    }

    @Test func glassAvailabilityDoesNotChangeDecision() {
        let policy = WindowBackgroundPolicy(
            settings: StubSettings(sidebarBlendModeRawValue: "behindWindow", isBackgroundGlassEnabled: true)
        )
        #expect(policy.shouldUseTransparentBackgroundWindow(glassEffectAvailable: true))
        #expect(policy.shouldUseTransparentBackgroundWindow(glassEffectAvailable: false))
    }

    @Test func transparentWindowFollowsSettings() {
        let on = WindowBackgroundPolicy(
            settings: StubSettings(sidebarBlendModeRawValue: "behindWindow", isBackgroundGlassEnabled: true)
        )
        let off = WindowBackgroundPolicy(
            settings: StubSettings(sidebarBlendModeRawValue: "withinWindow", isBackgroundGlassEnabled: false)
        )
        #expect(on.shouldUseTransparentBackgroundWindow(glassEffectAvailable: true))
        #expect(!off.shouldUseTransparentBackgroundWindow(glassEffectAvailable: true))
    }

    @Test func clearBackgroundOnTransparencyOrLowOpacity() {
        let opaqueSettings = WindowBackgroundPolicy(
            settings: StubSettings(sidebarBlendModeRawValue: "withinWindow", isBackgroundGlassEnabled: false)
        )
        // Transparent window forces clear.
        let glassSettings = WindowBackgroundPolicy(
            settings: StubSettings(sidebarBlendModeRawValue: "behindWindow", isBackgroundGlassEnabled: true)
        )
        #expect(
            glassSettings.shouldUseClearWindowBackground(
                for: 1.0,
                usesGhosttyGlassStyle: false,
                glassEffectAvailable: true
            )
        )
        // Ghostty glass style forces clear even when fully opaque.
        #expect(
            opaqueSettings.shouldUseClearWindowBackground(
                for: 1.0,
                usesGhosttyGlassStyle: true,
                glassEffectAvailable: true
            )
        )
        // Opacity below the 0.999 threshold forces clear.
        #expect(
            opaqueSettings.shouldUseClearWindowBackground(
                for: 0.5,
                usesGhosttyGlassStyle: false,
                glassEffectAvailable: true
            )
        )
        // Fully opaque, no glass, no transparency -> not clear.
        #expect(
            !opaqueSettings.shouldUseClearWindowBackground(
                for: 1.0,
                usesGhosttyGlassStyle: false,
                glassEffectAvailable: true
            )
        )
    }

    @Test func transparentBaseColorMatchesLegacy() {
        let policy = WindowBackgroundPolicy(
            settings: StubSettings(sidebarBlendModeRawValue: "withinWindow", isBackgroundGlassEnabled: false)
        )
        let color = policy.transparentWindowBaseColor
        let expected = NSColor.white.withAlphaComponent(0.001)
        #expect(color.alphaComponent == expected.alphaComponent)
    }
}
