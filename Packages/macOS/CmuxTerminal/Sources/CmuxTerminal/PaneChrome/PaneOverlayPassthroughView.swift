import AppKit

/// A non-interactive overlay `NSView` that never accepts events.
///
/// Pane ring/flash chrome must be purely additive: it sits above the terminal
/// surface but cannot accept first responder or swallow hit-testing, so clicks
/// and keystrokes always reach the terminal underneath. Both the notification
/// ring and the flash overlay use this as their layer host.
final class PaneOverlayPassthroughView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
