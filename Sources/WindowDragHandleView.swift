import AppKit
import SwiftUI

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
        override func hitTest(_ point: NSPoint) -> NSView? { self }
    }
}

