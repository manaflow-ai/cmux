import AppKit
public import SwiftUI

/// A SwiftUI overlay that hosts a ``ResizeGripperNSView`` to provide an `NSPopover`
/// diagonal-resize gripper, forwarding the corner-drag lifecycle through closures.
public struct ResizeGripperRepresentable: NSViewRepresentable {
    /// Returns the popover's current `(width, height)` at the start of a drag.
    public let onBegin: () -> (CGFloat, CGFloat)
    /// Reports a drag in progress as `(startWidth, startHeight, dx, dy)`.
    public let onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void
    /// Invoked when the drag ends.
    public let onEnd: () -> Void

    /// Creates a resize gripper overlay.
    /// - Parameters:
    ///   - onBegin: Returns the popover's current `(width, height)` when a drag starts.
    ///   - onDrag: Reports a drag as `(startWidth, startHeight, dx, dy)`.
    ///   - onEnd: Invoked when the drag ends.
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
