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
    /// - Returns: The same size on the source's right, `gap` away, when it
    ///   fits the screen; else on its left; else cascaded 28 pt from it and
    ///   kept on the screen (a source too wide for a neighbor).
    public func frame(beside source: CGRect, on screen: CGRect) -> CGRect {
        let right = source.offsetBy(dx: source.width + gap, dy: 0)
        if screen.contains(right) { return right }
        let left = source.offsetBy(dx: -(source.width + gap), dy: 0)
        if screen.contains(left) { return left }
        let step: CGFloat = 28
        for (dx, dy) in [(step, -step), (-step, step), (step, step), (-step, -step)] {
            let cascaded = source.offsetBy(dx: dx, dy: dy)
            if screen.contains(cascaded) { return cascaded }
        }
        return source.offsetBy(dx: step, dy: -step)
    }
}
