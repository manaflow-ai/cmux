public import AppKit

/// Backing `NSView` for ``MiddleClickCapture`` that hit-tests only middle-clicks.
public final class MiddleClickCaptureView: NSView {
    /// Invoked when a middle (button 2) mouse-down lands on this view.
    public var onMiddleClick: (() -> Void)?

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept middle-click so left-click selection and right-click context menus
        // continue to hit-test through to SwiftUI/AppKit normally.
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown,
              event.buttonNumber == 2 else {
            return nil
        }
        return self
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick?()
    }
}
