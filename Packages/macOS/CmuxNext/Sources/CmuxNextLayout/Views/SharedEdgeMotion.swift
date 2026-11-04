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
/// The rule (rule C, an animation is interruptible from its current value): a grab takes over at what is on screen.
/// - At the press (``Catch``, once), the drag's own value (a split's ratio, a column's width) is set to where its edge
///   shows from its anchor (the edge on the other side of the pane or span the drag resizes), so its size spring stops
///   where it shows; the edges on the dragged line then ride their anchor's translation spring. Every other edge the
///   new value moves keeps where it shows and its velocity (its spring goes on to its new place). The press moves nothing.
/// - On every move after it, an edge whose target the drag changes moves by as much as its target and keeps its
///   velocity, so the dragged pane changes 1:1 with the pointer; an edge whose target the drag does not change keeps
///   its spring. A component at rest lands on its new target exactly, so a drag with no spring running places frames
///   as before S2B.
/// Both neighbours of a shared edge see the same change, so they move together, and no size ever goes past where it
/// shows by a spring's leftover: nothing shows a negative width. A release's fling seeds only the edges it moved.
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
        place(&frame, at: target, caught: screen.activeDrag?.caught)
        return true
    }

    /// Sets `frame`'s target to `target` during a pointer gesture that does not animate. The press's pass (`caught`):
    /// every component keeps where it shows and its velocity, and an edge on the dragged line takes its anchor's
    /// velocity. Every other pass: each component (x, y, width, height) moves by as much as its target and keeps its
    /// velocity, so each edge moves by its own target's change. The alpha does as before S2B: opaque, at once for a
    /// frame the gesture retargets.
    static func place(_ frame: inout AnimatedFrame, at target: CGRect, caught: Catch? = nil) { // perf-hot: 4ms motion-frame
        let retargeted = frame.targetRect != target
        if let caught {
            let horizontal = caught.axis == .horizontal
            if horizontal {
                caught.retarget(start: &frame.x, extent: &frame.width, low: target.minX, high: target.maxX)
                (frame.y.target, frame.height.target) = (target.minY, target.height)
            } else {
                caught.retarget(start: &frame.y, extent: &frame.height, low: target.minY, high: target.maxY)
                (frame.x.target, frame.width.target) = (target.minX, target.width)
            }
        } else {
            shift(&frame.x, to: target.minX)
            shift(&frame.y, to: target.minY)
            shift(&frame.width, to: target.width)
            shift(&frame.height, to: target.height)
        }
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

    /// The press of a drag that starts while its edge springs: the dragged line (its rest coordinate along `axis`
    /// before the press, and `reach`, how far from it the edges on it lie: a pane's edge, the divider's, the next
    /// pane's across the gap) and its anchor's motion (`offset`, where the anchor shows less its rest place, and
    /// `velocity`). In the press's pass an edge on the line keeps where it shows less its new rest place, and runs at
    /// `velocity`: from then on it rides the anchor.
    struct Catch {
        var axis: SplitAxis
        var line: CGFloat
        var reach: CGFloat
        var offset: CGFloat
        var velocity: CGFloat

        /// One axis of the press's pass: both edges keep where they show; one on the line (before the press) whose
        /// target moved shows at its new target plus the anchor's offset (the same place, on the pixel the anchor's
        /// edges round to) and runs at the anchor's velocity.
        func retarget(start: inout SpringValue, extent: inout SpringValue, low: CGFloat, high: CGFloat) {
            var edges = Edges(start: start, extent: extent)
            if low != edges.lowTarget, abs(edges.lowTarget - line) <= reach { (edges.low, edges.lowSpeed) = (low + offset, velocity) }
            if high != edges.highTarget, abs(edges.highTarget - line) <= reach { (edges.high, edges.highSpeed) = (high + offset, velocity) }
            (edges.lowTarget, edges.highTarget) = (low, high)
            edges.write(start: &start, extent: &extent)
        }
    }

    /// The edges a layout change moved for one frame, compared with its targets before the change. A release seeds only
    /// these (``seed(_:moved:rate:)``). A frame with no target before is new in this pass (a split's pane, its
    /// divider): the release moved none of its edges, and it keeps the motion it starts with (it rides its neighbour).
    struct MovedEdges {
        var minX = false, maxX = false, minY = false, maxY = false
        var any: Bool { minX || maxX || minY || maxY }

        init(before: CGRect?, after: CGRect) {
            guard let before else { return }
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
    /// What a press on `kind` catches on `screen` (rule C): the drag's value that puts its edge's rest place where the
    /// edge shows from its anchor, and the ``Catch`` for the pass that lays it out. Nil when the edge shows at its rest
    /// place from its anchor and moves with it (nothing to catch), and for a row edge (its drag lays out a preview of
    /// rest rows).
    static func caught(_ kind: DividerHandleView.Kind, on screen: ScreenContentView) -> (value: DividerDragValue, motion: Catch)? {
        let geometry = screen.baseGeometry, style = screen.context.style, scale = screen.scale
        guard let handle = screen.dividerFrames[kind] else { return nil }
        let reach = max(style.dividerHitThickness, style.stripGap + style.dividerThickness) + 1
        /// Where the screen shows a coordinate (`pixelEdges`).
        func shown(_ value: CGFloat) -> CGFloat { scale > 0 ? (value * scale + 0.5).rounded(.down) / scale : value }
        switch kind {
        case let .split(id):
            guard let divider = geometry.dividers.first(where: { $0.id == id }) else { return nil }
            let horizontal = divider.axis == .horizontal
            let line = horizontal ? divider.frame.minX : divider.frame.minY
            let base = horizontal ? divider.container.minX : divider.container.minY
            guard let anchor = anchor(at: base, high: false, axis: divider.axis, within: divider.container, panes: screen.paneFrames),
                  let span = span(line: line, lineSpring: horizontal ? handle.x : handle.y, anchorAt: base, anchor: anchor, shown: shown) else {
                return nil
            }
            let ratio = SplitGeometry.ratio(forPointer: base + span, container: divider.container, axis: divider.axis, style: style,
                                            minimumA: divider.minimumA, minimumB: divider.minimumB)
            return (.ratio(id, ratio), Catch(axis: divider.axis, line: line, reach: reach, offset: anchor.offset, velocity: anchor.velocity))
        case let .columnEdge(id):
            guard let frame = geometry.columns[id], let column = screen.layout.columns.first(where: { $0.id == id }) else { return nil }
            let edge = geometry.columnEdges.first { $0.column == id }?.dockEdge
            let band = edge?.isBand == true, axis: SplitAxis = band ? .vertical : .horizontal
            // The dragged line, its anchor across the column, whether the anchor is the column's high edge, and which
            // way the extent grows from the anchor.
            let (line, base, high, sign): (CGFloat, CGFloat, Bool, CGFloat) = switch edge {
            case .right?: (frame.minX, frame.maxX, true, -1)
            case .top?: (frame.maxY, frame.minY, false, 1)
            case .bottom?: (frame.minY, frame.maxY, true, -1)
            case .left?, nil: (frame.maxX, frame.minX, false, 1)
            }
            guard let anchor = anchor(at: base, high: high, axis: axis, within: frame, panes: screen.paneFrames),
                  let span = span(line: line, lineSpring: band ? handle.y : handle.x, anchorAt: base, anchor: anchor, shown: shown) else {
                return nil
            }
            let minimum = band ? column.minimumSize(style: style).height : column.minimumSize(style: style).width
            let viewport = switch edge {
            case nil: geometry.stripWidth
            case .top?, .bottom?: screen.bounds.height
            case .left?, .right?: screen.bounds.width
            }
            let width = ColumnStripGeometry.fraction(forPixelWidth: max(span * sign, minimum), viewportWidth: viewport, gap: style.stripGap)
            return (.width(id, width), Catch(axis: axis, line: line, reach: reach, offset: anchor.offset, velocity: anchor.velocity))
        case .rowEdge:
            return nil
        }
    }

    /// The motion of the pane edge at `coordinate` along `axis` (its high edge with `high`) of a pane inside `within`:
    /// where it shows less its rest place, and its velocity.
    private static func anchor(at coordinate: CGFloat, high: Bool, axis: SplitAxis, within: CGRect,
                               panes: [PaneID: AnimatedFrame]) -> (offset: CGFloat, velocity: CGFloat)? {
        let room = within.insetBy(dx: -0.5, dy: -0.5)
        for frame in panes.values where room.contains(frame.targetRect) {
            let edges = axis == .horizontal ? Edges(start: frame.x, extent: frame.width) : Edges(start: frame.y, extent: frame.height)
            let (value, speed, target) = high ? (edges.high, edges.highSpeed, edges.highTarget) : (edges.low, edges.lowSpeed, edges.lowTarget)
            if abs(target - coordinate) < 0.5 { return (value - target, speed) }
        }
        return nil
    }

    /// How far the dragged line shows from its anchor, signed along the axis, as the screen draws both (on their
    /// pixels); nil when the line shows at its rest distance from the anchor and moves with it (nothing to catch).
    private static func span(line: CGFloat, lineSpring: SpringValue, anchorAt base: CGFloat, anchor: (offset: CGFloat, velocity: CGFloat),
                             shown: (CGFloat) -> CGFloat) -> CGFloat? {
        let offset = lineSpring.value - lineSpring.target
        guard abs(offset - anchor.offset) > 0.001 || abs(lineSpring.velocity - anchor.velocity) > 0.001 else { return nil }
        return shown(line + offset) - shown(base + anchor.offset)
    }
}
