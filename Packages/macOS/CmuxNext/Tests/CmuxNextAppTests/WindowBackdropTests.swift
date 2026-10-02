import CmuxNextDesign
import Testing
@testable import CmuxNextApp
@testable import CmuxNextTerminal

/// The window behind the terminal follows Ghostty's TerminalWindow rules for
/// `background-opacity` and `background-blur`
/// (ghostty/macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift).
struct WindowBackdropTests {
    @Test func opaqueConfigKeepsAnOpaqueWindow() {
        let backdrop = WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 20)
        #expect(backdrop.isOpaque)
        #expect(!backdrop.appliesBlur, "Ghostty sets no blur while the background is opaque")
    }

    @Test func translucentConfigBlursBehindTheWindow() {
        let backdrop = WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 20)
        #expect(!backdrop.isOpaque)
        #expect(backdrop.appliesBlur)
        // Ghostty uses white at 0.001, not clear, so the window keeps its
        // shadow and hit testing like a standard window.
        #expect(backdrop.windowBackgroundAlpha == 0.001)

        let unblurred = WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 0)
        #expect(!unblurred.isOpaque)
        #expect(unblurred.appliesBlur, "radius 0 clears an earlier blur")
    }

    /// macOS glass styles (`background-blur = macos-glass-*`, -1/-2) make the
    /// window non-opaque even at opacity 1 and set no CGS blur.
    @Test func glassStylesSetNoRadiusBlur() {
        let glass = WindowBackdrop(backgroundOpacity: 1, backgroundBlur: -1)
        #expect(!glass.isOpaque)
        #expect(!glass.appliesBlur)
    }
}

/// In a translucent window the root view paints the one translucent sheet.
/// Panes, terminal hosts and the surfaces' default background paint nothing,
/// so the terminal shows `background` at `background-opacity` once, as in
/// Ghostty (measured: Ghostty 0.8 over a blurred backdrop 69,70,66; cmux-next
/// sidebar 69,70,66 but terminal 39,40,35 from four stacked layers).
struct TranslucentSheetTests {
    @Test func onlyTheRootPaintsInATranslucentWindow() {
        let translucent = WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 20)
        #expect(!translucent.panesPaintBackground)
        let opaque = WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 20)
        #expect(opaque.panesPaintBackground)
    }

    @Test func surfacesDrawATransparentDefaultBackground() {
        #expect(GhosttyRuntimeSurfacePolicy.override(configuredOpacity: 0.8, opacityCells: false) == "background-opacity = 0")
        #expect(GhosttyRuntimeSurfacePolicy.override(configuredOpacity: 1, opacityCells: false) == nil)
        // With background-opacity-cells, explicit cell colors take the
        // opacity; a 0 override would erase them, so Ghostty's value stays.
        #expect(GhosttyRuntimeSurfacePolicy.override(configuredOpacity: 0.8, opacityCells: true) == nil)
    }
}
