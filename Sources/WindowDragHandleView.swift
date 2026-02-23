import AppKit
import SwiftUI

/// Returns whether the titlebar drag handle should capture a hit at `point`.
/// We only claim the hit when no sibling view already handles it, so interactive
/// controls layered in the titlebar (e.g. proxy folder icon) keep their gestures.
func windowDragHandleShouldCaptureHit(_ point: NSPoint, in dragHandleView: NSView) -> Bool {
    guard dragHandleView.bounds.contains(point) else { return false }
    guard let superview = dragHandleView.superview else { return true }

    for sibling in superview.subviews.reversed() {
        guard sibling !== dragHandleView else { continue }
        guard !sibling.isHidden, sibling.alphaValue > 0 else { continue }

        let pointInSibling = dragHandleView.convert(point, to: sibling)
        if sibling.hitTest(pointInSibling) != nil {
            return false
        }
    }

    return true
}

/// A transparent view that enables dragging the window when clicking in empty titlebar space.
/// This lets us keep `window.isMovableByWindowBackground = false` so drags in the app content
/// (e.g. sidebar tab reordering) don't move the whole window.
struct WindowDragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op
    }

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            windowDragHandleShouldCaptureHit(point, in: self) ? self : nil
        }
    }
}
