public import AppKit

/// A view inside a pane whose own content scrolls sideways at some points, such as a page with a
/// wide table or a long code line.
///
/// The layout claims horizontal scroll gestures over a columns screen to move its strip. Before it
/// does, it hit-tests the pane under the pointer and walks up from the hit view: the first view
/// that conforms answers whether the gesture belongs to its content instead. A view that says yes
/// gets the whole gesture (trackpad swipe or Shift-wheel), and the strip stays where it is.
///
/// ```swift
/// extension PageWebView: HorizontalScrollClaiming {
///     public func claimsHorizontalScroll(at point: NSPoint) -> Bool {
///         bounds.contains(point) && inputReadiness.isPointerOverSidewaysScroller
///     }
/// }
/// ```
@MainActor
public protocol HorizontalScrollClaiming: AnyObject {
    /// Whether a horizontal scroll at `point` belongs to this view's content.
    ///
    /// Called at the start of each trackpad gesture and for each discrete wheel event, on the main
    /// thread, from the scroll event monitor: answer from state you already have, without I/O.
    /// - Parameter point: The pointer, in this view's coordinates.
    /// - Returns: True when the content under `point` scrolls sideways itself.
    func claimsHorizontalScroll(at point: NSPoint) -> Bool
}
