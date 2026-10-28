import CoreGraphics

/// How far the strip can pan before a pane enters or leaves the viewport or the keep-alive band:
/// a pan event inside the span changes no pane's visibility, so it reports
/// none and the visibility pass is skipped. A pane is in a rect when their overlap is wider and
/// taller than `minimumOverlap` (`ScreenContentView.visiblePanes`, `KeepAliveBand`).
nonisolated struct PanVisibilitySpan: Equatable, Sendable {
    /// The pan delta (view x) just past which the first pane changes, toward negative x.
    var lower: CGFloat
    /// The same toward positive x.
    var upper: CGFloat

    /// Every delta: nothing moves in or out.
    static let unbounded = PanVisibilitySpan(lower: -.infinity, upper: .infinity)

    init(lower: CGFloat, upper: CGFloat) {
        self.lower = lower
        self.upper = upper
    }

    /// The span of the panes the strip moves, at `frames` (view coordinates, as they show now),
    /// against each of `rects` (the viewport, the keep-alive band).
    init(frames: [CGRect], rects: [CGRect], minimumOverlap: CGFloat = 0.5) {
        var lower = -CGFloat.infinity, upper = CGFloat.infinity
        for rect in rects where rect.width > minimumOverlap {
            for frame in frames where frame.width > minimumOverlap {
                // A vertical overlap the pan cannot change: never in this rect, whatever the delta.
                guard min(frame.maxY, rect.maxY) - max(frame.minY, rect.minY) > minimumOverlap else { continue }
                // In the rect exactly for deltas strictly between these two.
                for edge in [rect.minX + minimumOverlap - frame.maxX, rect.maxX - minimumOverlap - frame.minX] {
                    if edge >= 0 { upper = min(upper, edge) }
                    if edge <= 0 { lower = max(lower, edge) }
                }
            }
        }
        self.init(lower: lower, upper: upper)
    }

    /// Whether a pan of `delta` from where the span was measured keeps every pane in or out as it was.
    func contains(_ delta: CGFloat) -> Bool { lower < delta && delta < upper }
}
