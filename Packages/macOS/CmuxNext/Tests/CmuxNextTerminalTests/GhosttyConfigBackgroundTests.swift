import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// cmux.json's window background over the Ghostty config's own opacity and blur (`GhosttyConfigBackground`).
@MainActor struct GhosttyConfigBackgroundTests {
    /// An opacity step that keeps the window translucent in its material only repaints; a step to or from opaque,
    /// or another material, reloads the terminals at once.
    @Test func onlyAnOpaqueFlipOrAnotherMaterialReloadsTheSurfaces() {
        let frosted = GhosttyConfigBackground(opacity: 0.9, blur: 20)
        #expect(!frosted.surfacesChange(from: WindowBackgroundOverride(), to: WindowBackgroundOverride(opacity: 0.5)))
        #expect(frosted.surfacesChange(from: WindowBackgroundOverride(), to: WindowBackgroundOverride(opacity: 1)))
        #expect(frosted.surfacesChange(from: WindowBackgroundOverride(), to: WindowBackgroundOverride(material: .glass)))
        let opaque = GhosttyConfigBackground()
        #expect(opaque.surfacesChange(from: WindowBackgroundOverride(), to: WindowBackgroundOverride(opacity: 0.5)))
        #expect(!opaque.surfacesChange(from: WindowBackgroundOverride(opacity: 0.6), to: WindowBackgroundOverride(opacity: 0.5)))
    }

    /// The window's values are cmux.json's over the config's: a material with no opacity asks for translucency.
    @Test func theOverrideGoesOverTheConfigsValues() {
        let ghostty = GhosttyConfigBackground(opacity: 1, blur: -1)
        let kept = ghostty.resolved(WindowBackgroundOverride())
        #expect(kept.backgroundOpacity == 1 && kept.backgroundBlur == -1)
        let frosted = ghostty.resolved(WindowBackgroundOverride(material: .frosted))
        #expect(frosted.backgroundOpacity == WindowBackgroundOverride.defaultTranslucentOpacity && frosted.backgroundBlur == 20)
        let set = ghostty.resolved(WindowBackgroundOverride(opacity: 0.5, material: .unblurred))
        #expect(set.backgroundOpacity == 0.5 && set.backgroundBlur == 0)
    }
}
