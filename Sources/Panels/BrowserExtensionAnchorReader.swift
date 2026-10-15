import AppKit
import SwiftUI

/// Attaches a ``BrowserExtensionAnchor`` to the view it covers and, when
/// `onRightClick` is set, opens a menu directly on right-click.
///
/// Mount it as an overlay: it takes only right mouse downs (left clicks pass
/// through to the button below), so a pinned action's right-click shows
/// Chromium's action menu in one step, as Chrome does.
struct BrowserExtensionAnchorReader: NSViewRepresentable {
    let anchor: BrowserExtensionAnchor
    /// Called with the click's AppKit screen point.
    var onRightClick: ((CGPoint) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.onRightClick = onRightClick
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
        (view as? AnchorView)?.onRightClick = onRightClick
    }

    private final class AnchorView: NSView {
        var onRightClick: ((CGPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard onRightClick != nil, NSApp.currentEvent?.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let onRightClick, let window = event.window else { return super.rightMouseDown(with: event) }
            onRightClick(window.convertPoint(toScreen: event.locationInWindow))
        }
    }
}
