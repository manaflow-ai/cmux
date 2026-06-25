public import AppKit
public import SwiftUI

/// SwiftUI wrapper around a diagonal-resize grip for an AppKit-hosted popover.
///
/// The notifications popover is resized by dragging a corner grip. SwiftUI has no
/// drag-to-resize affordance for an AppKit popover, so this representable installs
/// an `NSView` that converts corner mouse drags into width/height deltas. The
/// owning view supplies the starting size on `onBegin`, applies live deltas in
/// `onDrag`, and finalizes on `onEnd`.
public struct ResizeGripperRepresentable: NSViewRepresentable {
    private let onBegin: () -> (CGFloat, CGFloat)
    private let onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void
    private let onEnd: () -> Void

    /// Creates a resize grip.
    /// - Parameters:
    ///   - onBegin: Invoked at mouse-down; returns the popover's current
    ///     `(width, height)` to anchor the drag.
    ///   - onDrag: Invoked on each drag with
    ///     `(startWidth, startHeight, deltaX, deltaY)`.
    ///   - onEnd: Invoked at mouse-up.
    public init(
        onBegin: @escaping () -> (CGFloat, CGFloat),
        onDrag: @escaping (CGFloat, CGFloat, CGFloat, CGFloat) -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.onBegin = onBegin
        self.onDrag = onDrag
        self.onEnd = onEnd
    }

    public func makeNSView(context: Context) -> ResizeGripperNSView {
        ResizeGripperNSView()
    }

    public func updateNSView(_ nsView: ResizeGripperNSView, context: Context) {
        nsView.onBegin = onBegin
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}

/// `NSView` that turns corner mouse drags into resize deltas and shows the
/// diagonal-resize cursor.
public final class ResizeGripperNSView: NSView {
    /// Invoked at mouse-down; returns the popover's current `(width, height)`.
    public var onBegin: () -> (CGFloat, CGFloat) = { (0, 0) }
    /// Invoked on each drag with `(startWidth, startHeight, deltaX, deltaY)`.
    public var onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void = { _, _, _, _ in }
    /// Invoked at mouse-up.
    public var onEnd: () -> Void = {}

    private var pressLocation: NSPoint?
    private var pressStartWidth: CGFloat = 0
    private var pressStartHeight: CGFloat = 0

    private static let diagonalResizeCursor: NSCursor = {
        // AppKit ships a NW–SE diagonal resize cursor for window corners but doesn't expose
        // it publicly. It has lived under this selector for years and is widely used by Mac
        // apps that need a diagonal resize affordance.
        let selector = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        if let method = NSCursor.responds(to: selector) ? NSCursor.perform(selector) : nil,
           let cursor = method.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return NSCursor.crosshair
    }()

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.diagonalResizeCursor)
    }

    public override func mouseDown(with event: NSEvent) {
        // NSEvent.mouseLocation is screen-coordinate and stable while the popover resizes.
        pressLocation = NSEvent.mouseLocation
        let (w, h) = onBegin()
        pressStartWidth = w
        pressStartHeight = h
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - start.x
        // Screen-y grows upward; popover should grow as the pointer moves down (toward
        // smaller screen-y), so invert.
        let dy = start.y - current.y
        onDrag(pressStartWidth, pressStartHeight, dx, dy)
    }

    public override func mouseUp(with event: NSEvent) {
        pressLocation = nil
        onEnd()
    }
}
