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
/// - At the press (`DividerDrag.catchShown`, once), the drag's own value (a split's ratio, a column's width) goes to
///   where its edge shows from its anchor (the edge across the pane or span it resizes, found from the layout's panes).
///   The screen lays that out in a pass that moves nothing: every frame keeps where it shows and its velocity, only its
///   target changes (``place(_:at:keepsShown:)``). Then each edge gets the change of speed that stops the dragged line
///   against its anchor, in proportion to how far that edge moves when the drag's value moves (``Influence``): the
///   dragged line stops against its anchor, the panes after it move with it as one block, an edge the value does not
///   move keeps its spring, and the two edges of a shared edge always get the same change.
/// - On every move after it, an edge whose target the drag changes moves by as much as its target and keeps its
///   velocity, so the dragged pane changes 1:1 with the pointer; an edge whose target the drag does not change keeps
///   its spring. A component at rest lands on its new target exactly, so a drag with no spring running places frames
///   as before S2B.
/// The dragged pane's size then has no spring leftover, so a drag never shows it past its rest size by one: nothing
/// shows a negative width. A shown extent the layout cannot hold (under its minimum, past the ratio range) is caught at
/// the nearest one it can hold, and the edge springs there from where it shows. A press that cannot catch (no anchor
/// frame, a value the probes cannot move, a row edge) while the screen moves turns the rule off for its drag: it is
/// the drag from before S2B. A release's fling seeds only the edges it moved.
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
        place(&frame, at: target, keepsShown: screen.activeDrag?.catching == true)
        return true
    }

    /// Sets `frame`'s target to `target` during a pointer gesture that does not animate. The press's pass
    /// (`keepsShown`): every component keeps where it shows and its velocity. Every other pass: each component (x, y,
    /// width, height) moves by as much as its target and keeps its velocity, so each edge moves by its own target's
    /// change. The alpha does as before S2B: opaque, at once for a frame the gesture retargets.
    static func place(_ frame: inout AnimatedFrame, at target: CGRect, keepsShown: Bool = false) { // perf-hot: 4ms motion-frame
        let retargeted = frame.targetRect != target
        if keepsShown {
            frame.setTarget(target)
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
    /// What a press catches (rule C): the drag's value that puts the dragged line's rest place where it shows from its
    /// anchor, the values a few points to either side (the probes, the longer way first: how far each edge moves with
    /// the line), and the change of speed that stops the line against its anchor.
    struct Caught {
        var value: DividerDragValue
        var probes: [DividerDragValue]
        var axis: SplitAxis
        var speedChange: CGFloat
        /// The line moves against its anchor (shows off its rest distance, or at another speed): the press catches it.
        /// False: `value` is the layout's own, and the press only checks what the drag will resize.
        var catches = true
        /// How far `value` must move the line's rest place to put it where it shows from its anchor. A value the layout
        /// clamps (a shown extent under a minimum, past the ratio range) moves it less: such a catch cannot hold the line
        /// still, and its press takes the drag from before S2B.
        var lineMove: CGFloat = 0
    }

    /// What a press on `kind` finds on `screen`.
    enum Press {
        case caught(Caught)
        /// No frame for the line or its anchor, or a row edge (its drag lays out a preview of rest rows).
        case cannotCatch
    }

    /// What a press on `kind` catches on `screen`.
    static func press(_ kind: DividerHandleView.Kind, on screen: ScreenContentView) -> Press {
        guard let handle = screen.dividerFrames[kind] else { return .cannotCatch }
        return caught(kind, handle: handle, on: screen)
    }

    private static func caught(_ kind: DividerHandleView.Kind, handle: AnimatedFrame, on screen: ScreenContentView) -> Press {
        let geometry = screen.baseGeometry, style = screen.context.style
        switch kind {
        case let .split(id):
            guard let divider = geometry.dividers.first(where: { $0.id == id }),
                  let side = screen.layout.tree(containing: id)?.node(for: id)?.a else { return .cannotCatch }
            let horizontal = divider.axis == .horizontal
            let base = horizontal ? divider.container.minX : divider.container.minY
            let line = horizontal ? divider.frame.minX : divider.frame.minY
            guard let anchor = anchor(nearest: base, high: false, axis: divider.axis, of: side.panes, in: screen.paneFrames) else {
                return .cannotCatch
            }
            let span = span(line: line, spring: horizontal ? handle.x : handle.y, base: base, anchor: anchor) ?? (line - base, anchor.velocity, false)
            func ratio(_ extent: CGFloat) -> DividerDragValue {
                .ratio(id, SplitGeometry.ratio(forPointer: base + extent, container: divider.container, axis: divider.axis, style: style,
                                               minimumA: divider.minimumA, minimumB: divider.minimumB))
            }
            return .caught(Caught(value: ratio(span.extent), probes: [ratio(span.extent + probeStep), ratio(span.extent - probeStep)],
                                  axis: divider.axis, speedChange: anchor.velocity - span.velocity, catches: span.moves,
                                  lineMove: base + span.extent - line))
        case let .columnEdge(id):
            guard let frame = geometry.columns[id], let column = screen.layout.columns.first(where: { $0.id == id }) else { return .cannotCatch }
            let edge = geometry.columnEdges.first { $0.column == id }?.dockEdge
            let band = edge?.isBand == true, axis: SplitAxis = band ? .vertical : .horizontal
            // The dragged line, its anchor across the column, whether the anchor is the column's high edge, and which
            // way the column's extent grows from the anchor.
            let (line, base, high, sign): (CGFloat, CGFloat, Bool, CGFloat) = switch edge {
            case .right?: (frame.minX, frame.maxX, true, -1)
            case .top?: (frame.maxY, frame.minY, false, 1)
            case .bottom?: (frame.minY, frame.maxY, true, -1)
            case .left?, nil: (frame.maxX, frame.minX, false, 1)
            }
            guard let anchor = anchor(nearest: base, high: high, axis: axis, of: column.root.panes, in: screen.paneFrames) else {
                return .cannotCatch
            }
            let span = span(line: line, spring: band ? handle.y : handle.x, base: base, anchor: anchor) ?? (line - base, anchor.velocity, false)
            let minimum = band ? column.minimumSize(style: style).height : column.minimumSize(style: style).width
            let viewport = switch edge {
            case nil: geometry.stripWidth
            case .top?, .bottom?: screen.bounds.height
            case .left?, .right?: screen.bounds.width
            }
            func width(_ extent: CGFloat) -> DividerDragValue {
                .width(id, ColumnStripGeometry.fraction(forPixelWidth: max(extent * sign, minimum), viewportWidth: viewport, gap: style.stripGap))
            }
            return .caught(Caught(value: width(span.extent), probes: [width(span.extent + probeStep * sign), width(span.extent - probeStep * sign)],
                                  axis: axis, speedChange: anchor.velocity - span.velocity, catches: span.moves,
                                  lineMove: base + span.extent - line))
        case .rowEdge:
            return .cannotCatch
        }
    }

    /// How far the probe moves the line from the caught value: past pixel rounding, short of any minimum it is not at.
    private static let probeStep: CGFloat = 8

    /// The motion of the edge nearest `coordinate` along `axis` (each pane's high edge with `high`) among `panes` (the
    /// panes on the anchor's side, from the layout): where it shows less its rest place, and its velocity.
    private static func anchor(nearest coordinate: CGFloat, high: Bool, axis: SplitAxis, of panes: [PaneID],
                               in frames: [PaneID: AnimatedFrame]) -> (offset: CGFloat, velocity: CGFloat)? {
        var best: (distance: CGFloat, offset: CGFloat, velocity: CGFloat)?
        for pane in panes {
            guard let frame = frames[pane] else { continue }
            let edges = axis == .horizontal ? Edges(start: frame.x, extent: frame.width) : Edges(start: frame.y, extent: frame.height)
            let (value, speed, target) = high ? (edges.high, edges.highSpeed, edges.highTarget) : (edges.low, edges.lowSpeed, edges.lowTarget)
            let distance = abs(target - coordinate)
            if distance < (best?.distance ?? .infinity) { best = (distance, value - target, speed) }
        }
        return best.map { ($0.offset, $0.velocity) }
    }

    /// How far the dragged line shows from its anchor (signed along the axis, not rounded) and its velocity; nil when
    /// the line shows at its rest distance from the anchor and moves with it.
    private static func span(line: CGFloat, spring: SpringValue, base: CGFloat, anchor: (offset: CGFloat, velocity: CGFloat))
        -> (extent: CGFloat, velocity: CGFloat, moves: Bool)? {
        let offset = spring.value - spring.target
        guard abs(offset - anchor.offset) > 0.001 || abs(spring.velocity - anchor.velocity) > 0.001 else { return nil }
        return ((line + offset) - (base + anchor.offset), spring.velocity, true)
    }

    /// How far each edge moved with the dragged line between the caught layout and the probe layout, as a fraction of
    /// the line's move: 1 for an edge on the line or after it, 0 for an edge the value does not move, a part for an edge
    /// a split shares out. The press gives each edge that fraction of the line's change of speed. Both layouts are laid
    /// out off the pixel grid (scale 0), so the two edges of a shared edge, a constant gap apart in both, move by the
    /// same amount and get the same change.
    struct Influence {
        var caught: ScreenGeometry
        var probe: ScreenGeometry
        var axis: SplitAxis
        var lineMove: CGFloat

        /// The influence of `kind`'s handle moving from `caught` to `probe` geometry; nil when the probe did not move it
        /// (both values clamped): the press then changes no speed.
        init?(_ kind: DividerHandleView.Kind, caught: ScreenGeometry, probe: ScreenGeometry, axis: SplitAxis) {
            guard let from = Self.target(kind, in: caught), let to = Self.target(kind, in: probe) else { return nil }
            let move = axis == .horizontal ? to.minX - from.minX : to.minY - from.minY
            guard abs(move) >= 1 else { return nil }
            (self.caught, self.probe, self.axis, lineMove) = (caught, probe, axis, move)
        }

        /// How fast `pane`'s size along the axis changes for each point per second of the line's change of speed.
        func sizeShare(_ pane: PaneID) -> CGFloat {
            guard let from = caught.panes[pane], let to = probe.panes[pane] else { return 0 }
            return (axis == .horizontal ? to.width - from.width : to.height - from.height) / lineMove
        }

        static func target(_ kind: DividerHandleView.Kind, in geometry: ScreenGeometry) -> CGRect? {
            switch kind {
            case let .split(id): geometry.dividers.first { $0.id == id }?.hitFrame
            case let .columnEdge(id): geometry.columnEdges.first { $0.column == id }?.hitFrame
            case let .rowEdge(column, upper): geometry.rowEdges.first { $0.column == column && $0.upper == upper }?.hitFrame
            }
        }

        /// Adds `speedChange` to `frame`'s edges along the axis, each in proportion to how far it moves from `from` to
        /// `to` (the frame's targets in the caught and the probe layout).
        func apply(_ speedChange: CGFloat, to frame: inout AnimatedFrame, from: CGRect?, to: CGRect?) {
            guard let from, let to else { return }
            let horizontal = axis == .horizontal
            let low = (horizontal ? to.minX - from.minX : to.minY - from.minY) / lineMove
            let high = (horizontal ? to.maxX - from.maxX : to.maxY - from.maxY) / lineMove
            guard low != 0 || high != 0 else { return }
            if horizontal {
                var edges = Edges(start: frame.x, extent: frame.width)
                (edges.lowSpeed, edges.highSpeed) = (edges.lowSpeed + speedChange * low, edges.highSpeed + speedChange * high)
                edges.write(start: &frame.x, extent: &frame.width)
            } else {
                var edges = Edges(start: frame.y, extent: frame.height)
                (edges.lowSpeed, edges.highSpeed) = (edges.lowSpeed + speedChange * low, edges.highSpeed + speedChange * high)
                edges.write(start: &frame.y, extent: &frame.height)
            }
        }
    }
}

extension SharedEdgeMotion {
    /// Whether some pane could show a negative size after this press (rule C keeps each edge's spring leftover through a
    /// drag): along either axis, its size's leftover from its rest size (`targets`: the caught layout's; nil: its own
    /// target) and its size's speed (plus `influence`'s share of `speedChange`), followed on `spring` for as long as it
    /// moves, must stay above minus `minimum` there: a drag (any mode) can shrink its rest size to that minimum, never
    /// under. Any pane, not only the ones this drag resizes: a modifier can resize others. True: the press takes the drag
    /// from before S2B, whose frames snap to rest and never show a negative size.
    static func mayShowNegativeSize(_ frames: [PaneID: AnimatedFrame], targets: [PaneID: CGRect]?, influence: Influence?,
                                    speedChange: CGFloat, minimum: CGSize, spring: SpringParameters) -> Bool {
        for (pane, frame) in frames {
            let target = targets?[pane] ?? frame.targetRect
            let share = influence?.sizeShare(pane) ?? 0
            let horizontal = influence?.axis != .vertical
            let width = (leftover: frame.width.value - target.width, speed: frame.width.velocity + (horizontal ? speedChange * share : 0))
            let height = (leftover: frame.height.value - target.height, speed: frame.height.velocity + (horizontal ? 0 : speedChange * share))
            if lowest(width, spring: spring) < 1 - minimum.width || lowest(height, spring: spring) < 1 - minimum.height { return true }
        }
        return false
    }

    /// The lowest leftover a spring from `state` (leftover, speed) reaches before it rests, sampled at a fortieth of its
    /// response (at most the settle horizon). Zero for a spring at rest.
    private static func lowest(_ state: (leftover: CGFloat, speed: CGFloat), spring: SpringParameters) -> CGFloat {
        guard state.leftover != 0 || state.speed != 0 else { return 0 }
        var value = SpringValue(0)
        (value.value, value.velocity) = (state.leftover, state.speed)
        let dt = max(spring.response, 0.05) / 40
        var lowest = min(state.leftover, 0)
        for _ in 0..<400 {
            value.step(dt, parameters: spring)
            lowest = min(lowest, value.value)
            if abs(value.value) < 0.25, abs(value.velocity) < 2 { break }
        }
        return lowest
    }
}
