@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// "Opacity should go all the way to 100%" (2026-10-21): every Opacity over a background picture
/// (window, workspace, pane; Settings, `cmux appearance set`, stored values) reaches 100%, and at
/// 100% the surface is fully opaque: no material, no art showing through.
@MainActor struct OpacityReachesFullTests {
    private let art = BackdropSelection.system(path: "/System/Library/Desktop Pictures/Sequoia.heic")

    @Test func theTintOverArtReachesOne() {
        #expect(WindowBackdrop.maximumWorkspaceTint == 1)
    }

    @Test func aFullTintOverArtMakesAnOpaqueWindowThatHidesTheArt() {
        let backdrop = WindowBackdrop(ThemeTokens.unresolved, selection: art, tintOpacity: 1)
        #expect(backdrop.isOpaque)
        #expect(backdrop.tintOpacity == 1)
        #expect(backdrop.panesPaintBackground)
        // Anything asked above 100% is 100%, never more see-through.
        #expect(WindowBackdrop(ThemeTokens.unresolved, selection: art, tintOpacity: 1.5).isOpaque)
    }

    @Test func workspaceAndWindowScopesKeepAFullTint() {
        let workspace = ThemeScope(level: .workspace)
        workspace.pinBackdropTint(1)
        #expect(workspace.backdropTintOpacity == 1)
        let window = ThemeScope(level: .room)
        window.setWindowBackdropTint(1)
        #expect(window.backdropTintOpacity == 1)
    }

    @Test(arguments: [("1", true), ("1.0", true), ("0.95", true), ("1.01", false), ("-0.1", false)])
    func theAppearanceCommandTakesOneHundredPercent(_ value: String, _ valid: Bool) {
        #expect(AppearanceProperty.opacity.accepts(value) == valid)
    }

    /// A pane at 100% over the window's art covers it with its plain background: before, its own
    /// opaque scope drew nothing and the window's art showed through.
    @Test func aPaneAtFullOpacityCoversTheWindowsArt() {
        var opaque = WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 0, liquidGlass: false)
        opaque.selection = art
        for mode in [PaneBackgroundMode.shared, .perPane] {
            let plan = PaneBackdropPlan.resolve(mode: mode, own: .selection(art), tint: nil, backdrop: opaque, inheritedHasArt: true)
            #expect(plan.art == nil)
            #expect(plan.cover, "mode \(mode)")
        }
    }
}
