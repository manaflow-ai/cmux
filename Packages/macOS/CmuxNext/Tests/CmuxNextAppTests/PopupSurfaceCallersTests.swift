import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextUpdater
import CmuxTheme
import Testing

/// Leo, 2026-10-12: every overlay that carries text is the solid popup surface. These had their own
/// glass, vibrancy or a translucent card fill: the Share cmux dialog, the refusal pill and the
/// omnibar's suggestion card, which joins the field's editing card.
@MainActor @Suite(.serialized) struct PopupSurfaceCallersTests {
    @Test func shareAndRefusalOverlaysAreThePopupSurface() {
        #expect(ShareCmuxView(writeToPasteboard: { _ in }).surface.material == .opaque)
        let hud = RefusalHUDView(frame: .zero)
        let surface = hud.subviews.compactMap { $0 as? OverlaySurfaceView }.first
        #expect(surface?.material == .opaque)
    }

    @Test func omnibarSuggestionsAreThePopupSurface() throws {
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Stress Purple")),
                          input: ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF)),
                          animated: false)
        let card = scope.perform { OmnibarStyle.cardFill }
        #expect(ThemedTooltipTests.same(card, scope.perform { Palette.popupSurface }))
    }
}
