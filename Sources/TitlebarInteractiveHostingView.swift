import AppKit
import SwiftUI

/// Hosts SwiftUI controls that must receive titlebar mouse-downs instead of triggering
/// window-management gestures.
///
/// Applying `titlebarInteractiveControl()` wraps a control in this host, which protects it from
/// both titlebar gestures at once:
/// - Window drags are suppressed because `mouseDownCanMoveWindow` is `false`.
/// - The standard titlebar double-click action (zoom/minimize) is suppressed because the host
///   registers itself with `MinimalModeTitlebarControlHitRegionRegistry`. Every synthetic
///   titlebar double-click monitor consults that registry and skips any control it contains, so
///   double-clicking the control runs the control's action without resizing the window.
@MainActor
final class TitlebarInteractiveHostingView<Content: View>: NSHostingView<Content> {
    nonisolated static var viewIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("cmux.titlebarInteractiveControl")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
        } else {
            MinimalModeTitlebarControlHitRegionRegistry.register(self)
        }
    }

    deinit {
        MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
    }
}
