public import AppKit

/// A transparent, passthrough `NSView` used as an overlay container for pane
/// flash, inactive dimming, drop-zone highlights, and the keyboard copy-mode
/// cursor/badge layers. It never becomes first responder and never participates
/// in hit-testing, so it overlays terminal content without intercepting events.
public final class GhosttyFlashOverlayView: NSView {
    public override var acceptsFirstResponder: Bool { false }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
