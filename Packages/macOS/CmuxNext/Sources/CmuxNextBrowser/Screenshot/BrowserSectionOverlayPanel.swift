import AppKit

/// The overlay's borderless panel: it takes key status for Esc and stays
/// with the page's window.
final class BrowserSectionOverlayPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.fullScreenAuxiliary]
        setAccessibilityIdentifier("browser.screenshotSection.overlay")
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}
