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
        let step = Self.cascadeStep
        for (dx, dy) in [(step, -step), (-step, step), (step, step), (-step, -step)] {
            let cascaded = source.offsetBy(dx: dx, dy: dy)
            if screen.contains(cascaded) { return cascaded }
        }
        return source.offsetBy(dx: step, dy: -step)
    }

    /// ``frame(beside:on:)``, but never exactly on a window already open at `occupied`: from a taken spot it steps on
    /// by the cascade step, as AppKit's `cascadeTopLeft(from:)` does, so two moves from one window open two windows
    /// that do not cover each other (v2.2.6-opt gate, mw-restart-three-windows).
    ///
    /// A step that would leave the screen goes back to the screen's top-left, unless a window already takes that
    /// spot: then it steps on, partly off screen (a zoomed or near-full source has no free spot on its screen, and a
    /// window partly off screen is better than one hidden under another).
    ///
    /// - Parameter occupied: The frames of the open windows, in screen coordinates (any screen).
    /// - Returns: A spot no window in `occupied` takes (the same top-left counts as taken).
    public func frame(beside source: CGRect, on screen: CGRect, avoiding occupied: [CGRect]) -> CGRect {
        func taken(_ frame: CGRect) -> Bool {
            occupied.contains { abs($0.minX - frame.minX) < 1 && abs($0.maxY - frame.maxY) < 1 }
        }
        var candidate = frame(beside: source, on: screen)
        let step = Self.cascadeStep
        // Each turn checks one new spot: a step moves down and right (AppKit's y grows up), and a jump to the
        // top-left is taken only when free, so the spots never repeat and `occupied.count` turns reach a free one.
        for _ in 0..<occupied.count {
            guard taken(candidate) else { break }
            let stepped = candidate.offsetBy(dx: step, dy: -step)
            var wrapped = stepped
            wrapped.origin = CGPoint(x: screen.minX + step, y: screen.maxY - stepped.height - step)
            candidate = screen.contains(stepped) || taken(wrapped) ? stepped : wrapped
        }
        return candidate
    }

    /// The step between cascaded windows, in points.
    static let cascadeStep: CGFloat = 28
}
