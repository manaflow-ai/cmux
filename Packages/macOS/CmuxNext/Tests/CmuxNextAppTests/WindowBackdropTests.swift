import CmuxNextDesign
import Testing
@testable import CmuxNextApp
@testable import CmuxNextTerminal

/// The window behind the terminal: opaque for an opaque config, otherwise
/// one material (Ghostty's glass styles as Liquid Glass, a blur radius as
/// frosted, no blur as plain see-through) and a non-opaque window at
/// Ghostty's 0.001 white.
struct WindowBackdropTests {
    @Test func opaqueConfigKeepsAnOpaqueWindow() {
        let backdrop = WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 20)
        #expect(backdrop.isOpaque)
        #expect(backdrop.material == .opaque)
    }

    @Test func translucentConfigWithABlurIsFrosted() {
        let backdrop = WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 20)
        #expect(!backdrop.isOpaque)
        #expect(backdrop.material == .frosted)
        // Ghostty uses white at 0.001, not clear, so the window keeps its
        // shadow and hit testing like a standard window.
        #expect(backdrop.windowBackgroundAlpha == 0.001)
        // No blur (`background-blur = false`): plainly see-through.
        #expect(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 0).material == .translucent)
    }

    /// macOS glass styles (`background-blur = macos-glass-*`, -1/-2) make the
    /// window non-opaque even at opacity 1.
    @Test func glassStylesAreLiquidGlass() {
        #expect(WindowBackdrop(backgroundOpacity: 1, backgroundBlur: -1).material == .glass(.regular))
        #expect(WindowBackdrop(backgroundOpacity: 1, backgroundBlur: -2).material == .glass(.clear))
        #expect(!WindowBackdrop(backgroundOpacity: 1, backgroundBlur: -1).isOpaque)
    }
}

/// In a translucent window the root's material and tint are the one
/// translucent sheet. Panes, terminal hosts and the surfaces' default
/// background paint nothing, so the terminal shows `background` at
/// `background-opacity` once, as in Ghostty (measured: Ghostty 0.8 over a
/// blurred backdrop 69,70,66; cmux-next sidebar 69,70,66 but terminal
/// 39,40,35 from four stacked layers).
struct TranslucentSheetTests {
    @Test(arguments: [(0.8, 20), (0.8, 0), (1.0, -1), (0.6, -2)])
    func panesStayClearOverEveryMaterial(opacity: Double, blur: Int) {
        let backdrop = WindowBackdrop(backgroundOpacity: opacity, backgroundBlur: blur)
        #expect(backdrop.material != .opaque)
        #expect(!backdrop.panesPaintBackground)
    }

    @Test func onlyAnOpaqueWindowsPanesPaint() {
        #expect(WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 20).panesPaintBackground)
    }

    @Test func surfacesDrawATransparentDefaultBackground() {
        #expect(GhosttyRuntimeSurfacePolicy.override(configuredOpacity: 0.8, opacityCells: false) == "background-opacity = 0")
        #expect(GhosttyRuntimeSurfacePolicy.override(configuredOpacity: 1, opacityCells: false) == nil)
        // With background-opacity-cells, explicit cell colors take the
        // opacity; a 0 override would erase them, so Ghostty's value stays.
        #expect(GhosttyRuntimeSurfacePolicy.override(configuredOpacity: 0.8, opacityCells: true) == nil)
    }
}
