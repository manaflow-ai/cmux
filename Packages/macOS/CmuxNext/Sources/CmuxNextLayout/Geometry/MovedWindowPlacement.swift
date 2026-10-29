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
    /// - Parameter occupied: The frames of the windows open on that screen.
    /// - Returns: The first free spot; after as many steps as there are open windows, the last one tried.
    public func frame(beside source: CGRect, on screen: CGRect, avoiding occupied: [CGRect]) -> CGRect {
        var candidate = frame(beside: source, on: screen)
        let step = Self.cascadeStep
        for _ in 0..<occupied.count {
            guard occupied.contains(where: { abs($0.minX - candidate.minX) < 1 && abs($0.maxY - candidate.maxY) < 1 }) else { break }
            // Down and right on screen (AppKit's y grows up), back to the screen's top-left when it would leave it.
            var next = candidate.offsetBy(dx: step, dy: -step)
            if !screen.contains(next) { next.origin = CGPoint(x: screen.minX + step, y: screen.maxY - next.height - step) }
            candidate = next
        }
        return candidate
    }

    /// The step between cascaded windows, in points.
    static let cascadeStep: CGFloat = 28
}
