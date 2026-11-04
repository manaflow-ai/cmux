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
/// The rule here: an edge whose target the gesture changes moves by as much as its target and keeps its velocity, so
/// it rides the spring it is on, moved by the drag; an edge whose target the gesture does not change keeps its spring.
/// Both neighbours of a shared edge see the same target change, so they move together. A component at rest lands on
/// its new target exactly, so a drag with no spring running places frames as before S2B. A drag measures the pointer
/// against the rest layout (`DividerDrag.start`, as before S2B): a press changes nothing, and the pointer's travel
/// changes the dragged pane's size 1:1 while its column's own spring carries it. A release's fling seeds the edges it
/// moved only.
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

    /// Sets `frame`'s target to `target` during a pointer gesture that does not animate: each component (x, y, width,
    /// height) moves by as much as its target and keeps its velocity, so each edge moves by its own target's change.
    /// The alpha does as before S2B: opaque, at once for a frame the gesture retargets.
    static func place(_ frame: inout AnimatedFrame, at target: CGRect) { // perf-hot: 4ms motion-frame
        let retargeted = frame.targetRect != target
        shift(&frame.x, to: target.minX)
        shift(&frame.y, to: target.minY)
        shift(&frame.width, to: target.width)
        shift(&frame.height, to: target.height)
        if retargeted { frame.alpha.snap(to: 1) } else { frame.alpha.target = 1 }
    }

    /// Retargets `value` to `target` and moves it by as much as its target moved, its velocity kept; at rest (on its
    /// old target, still) it is on the new target exactly, as a snap puts it.
    private static func shift(_ value: inout SpringValue, to target: CGFloat) {
        let delta = target - value.target
        guard delta != 0 else { return }
        let resting = value.velocity == 0 && value.value == value.target
        value.target = target
        value.value = resting ? target : value.value + delta
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
