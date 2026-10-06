public import AppKit

/// Backing `NSView` for ``MiddleClickCapture`` that fires on middle-clicks inside its bounds.
///
/// The view sits behind SwiftUI content that has its own gestures, and a hosting view can claim
/// the click before AppKit hit-tests down to this view. A local event monitor does not depend on
/// hit-testing, so the middle-click lands wherever the view is visible. Left- and right-clicks
/// are never touched.
public final class MiddleClickCaptureView: NSView {
    /// Invoked when a middle (button 2) mouse-down lands on this view.
    public var onMiddleClick: (() -> Void)?

    private var mouseDownMonitor: Any?

    deinit {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
        }
    }

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

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
        guard window != nil else { return }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handleMiddleMouseDown(
                    buttonNumber: event.buttonNumber,
                    window: event.window,
                    locationInWindow: event.locationInWindow
                ) ?? false
            }
            // Swallow a handled click so it doesn't also select the tab.
            return handled ? nil : event
        }
    }

    /// Fires ``onMiddleClick`` when a middle press at `locationInWindow` lands on the visible
    /// part of this view. Returns whether the press was consumed.
    func handleMiddleMouseDown(
        buttonNumber: Int,
        window eventWindow: NSWindow?,
        locationInWindow: NSPoint
    ) -> Bool {
        guard buttonNumber == 2,
              let window,
              eventWindow === window,
              !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(locationInWindow, from: nil)) else {
            return false
        }
        onMiddleClick?()
        return true
    }
}
