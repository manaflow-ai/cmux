import Testing
@testable import CmuxNextApp

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
        // shadow and hit testing like Terminal.app.
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
