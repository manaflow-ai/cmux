import CmuxNextDesign
import CoreGraphics

/// FRAME OWNER REFACTOR S2B: a gesture moves pane and divider edges, never whole frames (`motion.frameOwner.sharedEdges`,
/// latched per drag in ``DividerDragState/sharedEdges``).
///
/// Two panes that share an edge (a column edge, a split's divider) hold it as two values, one in each frame, and they
/// agree only because every motion moves both the same way. A drag that starts while a spring runs (a key resize, a
/// release) breaks that when it snaps a whole frame it retargets: a column whose right edge the drag changes also has
/// its left edge snapped to the place the spring was still taking it, while the pane beside it is still on that spring,
/// so the shell shows between them, or they overlap (SharedEdgeDuringSpringTests: 59 pt open, 47 pt overlap).
///
/// The rule here: an edge whose target the gesture changes lands on it; an edge whose target it does not change keeps
/// its spring. Both neighbours of a shared edge see the same target change, so they always land together or spring on
/// together. A release's fling seeds the same edges only.
enum SharedEdgeMotion {
    /// One axis of a frame as its two edges: where each shows, how fast it moves, and where it goes.
    private struct Edges {
        var low: CGFloat, lowSpeed: CGFloat, lowTarget: CGFloat
        var high: CGFloat, highSpeed: CGFloat, highTarget: CGFloat

        init(start: SpringValue, extent: SpringValue) {
            (low, lowSpeed, lowTarget) = (start.value, start.velocity, start.target)
            (high, highSpeed, highTarget) = (start.value + extent.value, start.velocity + extent.velocity, start.target + extent.target)
        }

        /// Writes the edges back as a start and an extent (same targets).
        func write(start: inout SpringValue, extent: inout SpringValue) {
            (start.value, start.velocity, start.target) = (low, lowSpeed, lowTarget)
            (extent.value, extent.velocity, extent.target) = (high - low, highSpeed - lowSpeed, highTarget - lowTarget)
        }
    }

    /// `ScreenContentView.place` during a person's drag on `screen` that latched `motion.frameOwner.sharedEdges` and does
    /// not animate: the drag moves edges, not whole frames. Returns false (the caller places as before S2B) otherwise.
    static func place(_ frame: inout AnimatedFrame, at target: CGRect, animated: Bool, on screen: ScreenContentView) -> Bool { // perf-hot: 4ms motion-frame
        guard !animated, screen.activeDrag?.sharedEdges == true, screen.context.model.isGestureActive, !screen.context.reduceMotion else {
            return false
        }
        place(&frame, at: target)
        return true
    }

    /// Sets `frame`'s target to `target` during a pointer gesture that does not animate: each edge whose target changed
    /// lands on it, every other edge keeps where it shows and its velocity (its spring goes on).
    static func place(_ frame: inout AnimatedFrame, at target: CGRect) { // perf-hot: 4ms motion-frame
        let before = frame.targetRect
        frame.setTarget(target, alpha: 1)
        land(start: &frame.x, extent: &frame.width, low: target.minX != before.minX, high: target.maxX != before.maxX)
        land(start: &frame.y, extent: &frame.height, low: target.minY != before.minY, high: target.maxY != before.maxY)
    }

    /// Lands the low and/or high edge of one axis on its target; an edge that did not move keeps its value and speed.
    private static func land(start: inout SpringValue, extent: inout SpringValue, low: Bool, high: Bool) {
        guard low || high else { return }
        var edges = Edges(start: start, extent: extent)
        if low { (edges.low, edges.lowSpeed) = (edges.lowTarget, 0) }
        if high { (edges.high, edges.highSpeed) = (edges.highTarget, 0) }
        edges.write(start: &start, extent: &extent)
    }

    /// The edges a layout change moved for one frame, compared with its targets before the change. A release seeds only
    /// these (``seed(_:moved:rate:)``). A frame with no target before (new) moved on every edge.
    struct MovedEdges {
        var minX = false, maxX = false, minY = false, maxY = false
        var any: Bool { minX || maxX || minY || maxY }

        init(before: CGRect?, after: CGRect) {
            guard let before else {
                (minX, maxX, minY, maxY) = (true, true, true, true)
                return
            }
            (minX, maxX) = (before.minX != after.minX, before.maxX != after.maxX)
            (minY, maxY) = (before.minY != after.minY, before.maxY != after.maxY)
        }
    }

    /// A release fling: every edge the release moved starts with `rate` (a fraction of its travel per second), as
    /// `SplitMotion.seed` gives whole frames; an edge it did not move keeps the velocity of the spring it is on.
    static func seed(_ frame: inout AnimatedFrame, moved: MovedEdges, rate: CGFloat) {
        guard moved.any else { return }
        seed(start: &frame.x, extent: &frame.width, low: moved.minX, high: moved.maxX, rate: rate)
        seed(start: &frame.y, extent: &frame.height, low: moved.minY, high: moved.maxY, rate: rate)
    }

    private static func seed(start: inout SpringValue, extent: inout SpringValue, low: Bool, high: Bool, rate: CGFloat) {
        guard low || high else { return }
        var edges = Edges(start: start, extent: extent)
        if low { edges.lowSpeed = (edges.lowTarget - edges.low) * rate }
        if high { edges.highSpeed = (edges.highTarget - edges.high) * rate }
        edges.write(start: &start, extent: &extent)
    }
}

extension SharedEdgeMotion {
    /// How far the edge a drag of `kind` grabs shows from its rest place on `screen` now, along the drag's axis: a drag
    /// that starts while that edge springs measures the pointer from where the edge shows, so the edge starts under
    /// the pointer, not at its rest place plus the pointer's move. Zero at rest, and for a row edge (its drag lays out
    /// a preview of the rest rows) or with `sharedEdges` off (the drag's latched `motion.frameOwner.sharedEdges`).
    static func shownDrift(of kind: DividerHandleView.Kind, on screen: ScreenContentView, sharedEdges: Bool) -> CGFloat {
        guard sharedEdges, let frame = screen.dividerFrames[kind] else { return 0 }
        switch kind {
        case let .split(id):
            guard let divider = screen.geometry.dividers.first(where: { $0.id == id }) else { return 0 }
            return divider.axis == .horizontal ? frame.x.value - frame.x.target : frame.y.value - frame.y.target
        case let .columnEdge(column):
            let band = screen.geometry.columnEdges.first(where: { $0.column == column })?.dockEdge?.isBand == true
            return band ? frame.y.value - frame.y.target : frame.x.value - frame.x.target
        case .rowEdge:
            return 0
        }
    }
}
