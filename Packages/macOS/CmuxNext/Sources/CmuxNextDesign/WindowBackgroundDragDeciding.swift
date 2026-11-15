public import AppKit

/// A view that says, point by point, whether a press on it moves its window: a window moved by its background (the
/// floating Chief's) asks the views under a press, innermost first, before its own rule.
///
/// One view's `mouseDownCanMoveWindow` answers for all of it, but a chat transcript is one view with messages (whose
/// text selects) and empty space between them.
///
/// ```swift
/// extension TranscriptView: WindowBackgroundDragDeciding {
///     func pressMovesWindow(atWindowPoint point: CGPoint, hit: NSView) -> Bool? {
///         hit.isDescendant(of: self) ? isEmptySpace(at: convert(point, from: nil)) : nil
///     }
/// }
/// ```
@MainActor
public protocol WindowBackgroundDragDeciding: AnyObject {
    /// Whether a press at `point` (window coordinates) on `hit`, a view under this one, moves the window.
    ///
    /// - Parameters:
    ///   - point: Where the press is, in the window's coordinates.
    ///   - hit: The view the press hits (this view or one under it).
    /// - Returns: True moves the window, false keeps the press for the views; nil leaves it to the views above and
    ///   the window's own rule.
    func pressMovesWindow(atWindowPoint point: CGPoint, hit: NSView) -> Bool?
}
