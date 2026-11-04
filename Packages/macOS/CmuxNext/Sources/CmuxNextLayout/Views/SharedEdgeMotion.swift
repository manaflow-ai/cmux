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
/// The rule (rule D, the refactor owner, 2026-11-04; an animation is interruptible from its current value): a grab
/// holds the dragged line where the screen draws it.
/// - At the press (`DividerDrag.catchShown`, once), the drag's own value (a split's ratio, a column's width) goes to
///   the value that rests the line on the pixel it is drawn on, measured from its anchor's REST place (the edge across
///   the pane or span it resizes). The screen lays that out in a pass that moves nothing (every frame keeps where it
///   shows and its velocity, only its target changes: ``place(_:at:keepsShown:)``). Then each edge gets the change of
///   speed and place that stops the line on its pixel, in proportion to how far that edge moves when the drag's value
///   moves (``Influence``): the line and every edge after it stop, an edge the value does not move (the anchor and the
///   edges before it) keeps its spring, and the two edges of a shared edge always get the same change. The drag
///   measures the pointer from the drawn line, so the pointer alone moves it, 1:1, and a still pointer holds it, also
///   while its column slides. Where the anchor's rest place leaves the pane less than its minimum, the layout clamps
///   the line at the anchor's rest place plus that minimum, and the line springs there from where it is drawn, no
///   further; it never shows behind the pointer (the pointer takes over the part of that spring it passes:
///   `SharedEdgeClamp`).
/// - On every move after it, an edge whose target the drag changes moves by as much as its target and keeps its
///   velocity; an edge whose target the drag does not change keeps its spring. A component at rest lands on its new
///   target exactly, so a drag with no spring running places frames as before S2B.
/// A press that cannot hold while the screen moves turns the rule off for its drag, which is then the drag from before
/// S2B (every frame it retargets snaps to its rest place): no frame for the line, a value the probes cannot move, a row
/// edge, a view offset that places the line and still moves (the strip's camera, a scroll area or a scrolling row: the
/// line's own spring cannot hold it where it is drawn), or a pane whose size spring could take it further under its
/// rest size than a pane's minimum, also with any part of a clamp's spring taken off (a drag that shrinks it to its
/// minimum would then show it with a negative size). A release's fling seeds only the edges it moved.
enum SharedEdgeMotion {
    /// One axis of a frame as its two edges: where each shows, how fast it moves, and where it goes.
    struct Edges {
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
    /// What a press catches (rule D): the drag's value that puts the dragged line's rest place where the screen draws
    /// the line now (`valueAt` gives it for any extent from the anchor's rest place `base`: the probes, a few points
    /// to either side of where the layout rests the line, measure how far each edge moves with it), the change of speed
    /// and of place that stop the line on its drawn pixel, and that drawn place (`held`, in the geometry's space along
    /// the axis: the drag measures the pointer from it).
    struct Caught {
        var value: DividerDragValue
        var valueAt: (CGFloat) -> DividerDragValue
        var base: CGFloat
        var axis: SplitAxis
        /// The line's velocity, negated: added to the line, it stops it.
        var speedChange: CGFloat
        /// The drawn place less the line's value: added to the line, it puts it on its drawn pixel.
        var placeChange: CGFloat
        var held: CGFloat
        /// The line moves (off its target, or with a velocity): the press holds it. False: it rests, nothing to hold.
        var catches = true
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
            guard let divider = geometry.dividers.first(where: { $0.id == id }) else { return .cannotCatch }
            let horizontal = divider.axis == .horizontal
            let base = horizontal ? divider.container.minX : divider.container.minY
            let line = horizontal ? divider.frame.minX : divider.frame.minY
            let shown = ShownPixels(screen: screen, kind: kind, axis: divider.axis)
            guard !shown.moves else { return .cannotCatch }
            let hold = Hold(line: line, spring: horizontal ? handle.x : handle.y, shown: shown)
            func ratio(_ extent: CGFloat) -> DividerDragValue {
                .ratio(id, SplitGeometry.ratio(forPointer: base + extent, container: divider.container, axis: divider.axis, style: style,
                                               minimumA: divider.minimumA, minimumB: divider.minimumB))
            }
            return .caught(Caught(value: ratio(hold.drawn - base), valueAt: ratio, base: base, axis: divider.axis, speedChange: -hold.velocity,
                                  placeChange: hold.drawn - hold.value, held: hold.drawn, catches: hold.moves))
        case let .columnEdge(id):
            guard let frame = geometry.columns[id], let column = screen.layout.columns.first(where: { $0.id == id }) else { return .cannotCatch }
            let edge = geometry.columnEdges.first { $0.column == id }?.dockEdge
            let band = edge?.isBand == true, axis: SplitAxis = band ? .vertical : .horizontal
            // The dragged line, its anchor across the column (at rest), and which way the column's extent grows from it.
            let (line, base, sign): (CGFloat, CGFloat, CGFloat) = switch edge {
            case .right?: (frame.minX, frame.maxX, -1)
            case .top?: (frame.maxY, frame.minY, 1)
            case .bottom?: (frame.minY, frame.maxY, -1)
            case .left?, nil: (frame.maxX, frame.minX, 1)
            }
            let shown = ShownPixels(screen: screen, kind: kind, axis: axis)
            guard !shown.moves else { return .cannotCatch }
            let hold = Hold(line: line, spring: band ? handle.y : handle.x, shown: shown)
            let minimum = band ? column.minimumSize(style: style).height : column.minimumSize(style: style).width
            let viewport = switch edge {
            case nil: geometry.stripWidth
            case .top?, .bottom?: screen.bounds.height
            case .left?, .right?: screen.bounds.width
            }
            func width(_ extent: CGFloat) -> DividerDragValue {
                .width(id, ColumnStripGeometry.fraction(forPixelWidth: max(extent * sign, minimum), viewportWidth: viewport, gap: style.stripGap))
            }
            return .caught(Caught(value: width(hold.drawn - base), valueAt: width, base: base, axis: axis, speedChange: -hold.velocity,
                                  placeChange: hold.drawn - hold.value, held: hold.drawn, catches: hold.moves))
        case .rowEdge:
            return .cannotCatch
        }
    }

    /// The dragged line's place along the axis (in the geometry's space): its rest place `line` plus how far its spring
    /// shows it from its target, the pixel the screen draws that on, and its velocity.
    private struct Hold {
        var value: CGFloat
        var drawn: CGFloat
        var velocity: CGFloat
        var moves: Bool

        init(line: CGFloat, spring: SpringValue, shown: ShownPixels) {
            value = line + spring.value - spring.target
            drawn = shown.edge(value)
            velocity = spring.velocity
            moves = abs(spring.value - spring.target) > 0.001 || abs(spring.velocity) > 0.001
        }
    }

    /// The dragged line's rest place along `axis` in `geometry` (the place the drag's pointer offset is taken from).
    static func restLine(_ kind: DividerHandleView.Kind, axis: SplitAxis, in geometry: ScreenGeometry) -> CGFloat? {
        switch kind {
        case let .split(id):
            guard let divider = geometry.dividers.first(where: { $0.id == id }) else { return nil }
            return axis == .horizontal ? divider.frame.minX : divider.frame.minY
        case let .columnEdge(id):
            guard let frame = geometry.columns[id] else { return nil }
            return switch geometry.columnEdges.first(where: { $0.column == id })?.dockEdge {
            case .right?: frame.minX
            case .top?: frame.maxY
            case .bottom?: frame.minY
            case .left?, nil: frame.maxX
            }
        case .rowEdge:
            return nil
        }
    }

    /// How far a probe moves the line from where the caught value rests it: past pixel rounding, short of any minimum
    /// it is not at.
    static let probeStep: CGFloat = 8

    /// Where the screen draws a coordinate of `kind`'s geometry along `axis`: placed in the view (the strip's scroll, a
    /// scroll area's and a scrolling row's offsets, as `ScreenContentView.applyPresentation` places hosts and handles) and
    /// rounded to the device pixel (`pixelEdges`), back in the geometry's space.
    struct ShownPixels {
        var shift: CGFloat
        var scale: CGFloat
        /// The view offset that places the line along the axis still moves (the strip's camera, a scroll area's or a
        /// scrolling row's spring): the line cannot be held where it is drawn by stopping its own spring, so the press
        /// takes the drag from before S2B.
        var moves: Bool

        init(screen: ScreenContentView, kind: DividerHandleView.Kind, axis: SplitAxis) {
            shift = axis == .horizontal ? (screen.scrolls(kind) ? screen.stripShift : 0) - screen.areaOffset(of: kind) : -screen.rowOffset(of: kind)
            scale = screen.scale
            moves = SharedEdgeMotion.viewOffsetMoves(of: kind, axis: axis, on: screen)
        }

        func edge(_ value: CGFloat) -> CGFloat {
            guard scale > 0 else { return value }
            return ((value + shift) * scale + 0.5).rounded(.down) / scale - shift
        }
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

        /// How far a frame's low and high edges move along the axis for each point the line moves (its targets in the
        /// caught layout `from` and the probe layout `to`); 1 for an edge that moves as the line does.
        func fractions(from: CGRect?, to: CGRect?) -> (low: CGFloat, high: CGFloat)? {
            guard let from, let to else { return nil }
            let horizontal = axis == .horizontal
            return ((horizontal ? to.minX - from.minX : to.minY - from.minY) / lineMove,
                    (horizontal ? to.maxX - from.maxX : to.maxY - from.maxY) / lineMove)
        }

        /// How fast `pane`'s size along the axis changes for each point per second of the line's change of speed.
        func sizeShare(_ pane: PaneID) -> CGFloat {
            guard let from = caught.panes[pane], let to = probe.panes[pane] else { return 0 }
            return (axis == .horizontal ? to.width - from.width : to.height - from.height) / lineMove
        }

        /// A fraction of 1: the edge moves as the line does.
        static func rigid(_ fraction: CGFloat) -> Bool { abs(fraction - 1) < 0.000_001 }

        static func target(_ kind: DividerHandleView.Kind, in geometry: ScreenGeometry) -> CGRect? {
            switch kind {
            case let .split(id): geometry.dividers.first { $0.id == id }?.hitFrame
            case let .columnEdge(id): geometry.columnEdges.first { $0.column == id }?.hitFrame
            case let .rowEdge(column, upper): geometry.rowEdges.first { $0.column == column && $0.upper == upper }?.hitFrame
            }
        }

        /// Adds `speedChange` to `frame`'s edges along the axis, each in proportion to how far it moves from `from` to `to`
        /// (the frame's targets in the caught and the probe layout), and `placeChange` to the ones that move as the line
        /// does: an edge that moves with the line stops with it, on its pixel; an edge the value does not move keeps its
        /// spring.
        func apply(_ speedChange: CGFloat, placeChange: CGFloat, to frame: inout AnimatedFrame, from: CGRect?, to: CGRect?) {
            guard let (low, high) = fractions(from: from, to: to), low != 0 || high != 0 else { return }
            let horizontal = axis == .horizontal
            // The place change (under a pixel) goes only to the edges that move with the line as one (fraction 1): it puts
            // them on the line's drawn pixel. An edge a split shares out keeps its place: a part of a pixel could round
            // it onto the next pixel, and the press must move nothing on screen.
            func rigid(_ fraction: CGFloat) -> CGFloat { Self.rigid(fraction) ? 1 : 0 }
            func change(_ edges: inout Edges) {
                (edges.lowSpeed, edges.highSpeed) = (edges.lowSpeed + speedChange * low, edges.highSpeed + speedChange * high)
                (edges.low, edges.high) = (edges.low + placeChange * rigid(low), edges.high + placeChange * rigid(high))
            }
            if horizontal {
                var edges = Edges(start: frame.x, extent: frame.width)
                change(&edges)
                edges.write(start: &frame.x, extent: &frame.width)
            } else {
                var edges = Edges(start: frame.y, extent: frame.height)
                change(&edges)
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
    /// under. Any pane, not only the ones this drag resizes: a modifier can resize others. With `clampLeftover` (the
    /// line's leftover from where the layout clamps it, after the press; it does not move then), also the size along the
    /// axis without the pane's share of it: the pointer can take any part of the clamp's spring off at any time
    /// (`SharedEdgeClamp.follow`), and springs are linear, so the size stays between the two paths. True: the press takes
    /// the drag from before S2B, whose frames snap to rest and never show a negative size.
    static func mayShowNegativeSize(_ frames: [PaneID: AnimatedFrame], targets: [PaneID: CGRect]?, influence: Influence?,
                                    speedChange: CGFloat, clampLeftover: CGFloat = 0, minimum: CGSize, spring: SpringParameters) -> Bool {
        let horizontal = influence?.axis != .vertical
        for (pane, frame) in frames {
            let target = targets?[pane] ?? frame.targetRect
            let share = influence?.sizeShare(pane) ?? 0
            let width = (leftover: frame.width.value - target.width, speed: frame.width.velocity + (horizontal ? speedChange * share : 0))
            let height = (leftover: frame.height.value - target.height, speed: frame.height.velocity + (horizontal ? 0 : speedChange * share))
            if lowest(width, spring: spring) < 1 - minimum.width || lowest(height, spring: spring) < 1 - minimum.height { return true }
            guard abs(clampLeftover) > 0.001 else { continue } // a clamped press only (`SharedEdgeClamp`'s threshold)
            let along = horizontal ? width : height
            let released: (leftover: CGFloat, speed: CGFloat) = (along.leftover - share * clampLeftover, along.speed)
            if lowest(released, spring: spring) < 1 - (horizontal ? minimum.width : minimum.height) { return true }
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

extension SharedEdgeMotion {
    /// Whether the view offset that places `kind`'s line along `axis` on `screen` still moves: the strip's camera (for a
    /// line that scrolls, horizontal), its scroll area's spring (horizontal) or its scrolling row's spring (vertical).
    static func viewOffsetMoves(of kind: DividerHandleView.Kind, axis: SplitAxis, on screen: ScreenContentView) -> Bool {
        func moves(_ spring: SpringValue) -> Bool { abs(spring.value - spring.target) > 0.001 || abs(spring.velocity) > 0.001 }
        if axis == .horizontal {
            if screen.scrolls(kind), moves(screen.scroll) { return true }
            guard case let .split(id) = kind, let area = screen.baseGeometry.scrollAreaOfSplit[id] else { return false }
            return screen.areaScrolls[area].map { moves($0.state.spring) } ?? false
        }
        let column: ColumnID? = switch kind {
        case let .split(id): screen.baseGeometry.rowColumnOfSplit[id]
        case let .rowEdge(id, _): id
        case .columnEdge: nil
        }
        return column.flatMap { screen.rowScrolls[$0] }.map { moves($0.state.spring) } ?? false
    }
}
