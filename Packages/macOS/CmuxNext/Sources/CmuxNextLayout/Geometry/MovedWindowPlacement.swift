public import CoreGraphics

/// Where Move to New Window opens the new window: beside the window the
/// content leaves, never on top of it.
///
/// ```swift
/// let frame = MovedWindowPlacement().frame(beside: source.frame, on: screen.visibleFrame)
/// ```
public nonisolated struct MovedWindowPlacement: Sendable, Hashable {
    /// Space between the old window and the new one, in points.
    public var gap: CGFloat

    /// - Parameter gap: Space between the two windows (12 pt by default).
    public init(gap: CGFloat = 12) {
        self.gap = gap
    }

    /// The new window's frame for content leaving a window at `source` on a
    /// screen whose visible frame is `screen`.
    ///
    /// - Parameters:
    ///   - source: The frame of the window the content leaves.
    ///   - screen: The visible frame of that window's screen.
    /// - Returns: A stub that returns `source` (the failing-first commit).
    public func frame(beside source: CGRect, on screen: CGRect) -> CGRect {
        source
    }
}
