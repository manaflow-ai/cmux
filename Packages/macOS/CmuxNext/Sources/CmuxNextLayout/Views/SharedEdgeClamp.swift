import CmuxNextDesign
import CoreGraphics

/// FRAME OWNER REFACTOR S2B, rule D's clamp: a press whose drawn line the layout does not rest there (the anchor's rest
/// place leaves the pane less than its minimum) springs the line from where it is drawn to the clamp. Each edge carries
/// its share of that spring (its fraction of the line's move, `SharedEdgeMotion.Influence`; springs are linear, so its
/// part is always that share of the line's leftover), and a drag move keeps it (each edge moves by its target's change).
/// The pointer still holds the line: where the line shows behind the pointer, ``follow(_:on:)`` drops the part of that
/// spring the pointer has passed, so the line shows under the pointer and the rest of the spring takes it on toward its
/// target. The anchor still springs too: where it comes to the line faster than the line springs away, ``push(on:)``
/// gives the line the anchor's motion, so the pane between them never shows under its minimum. The press checks that no
/// pane can show a negative size with any part of the clamp's spring dropped (`SharedEdgeMotion.mayShowNegativeSize`,
/// `clampLeftover`).
struct SharedEdgeClamp {
    var kind: DividerHandleView.Kind
    var axis: SplitAxis
    /// +1 when the line springs toward growing coordinates (its target is past where it was drawn that way), -1 else.
    var free: CGFloat
    /// How far each frame's low and high edges move along the axis for each point the line moves; frames it moves only.
    var panes: [PaneID: (low: CGFloat, high: CGFloat)]
    var dividers: [DividerHandleView.Kind: (low: CGFloat, high: CGFloat)]
    /// The edge across the pane the line springs away from (the anchor: an edge of a pane the line resizes that does not
    /// move with the line, on the side opposite `free`), and which of that pane's edges it is. Nil: none (a clamp at a
    /// widest share has no edge behind the line).
    var anchor: (pane: PaneID, high: Bool)?
    /// How far the line's leftover may come behind the anchor's, along `free`: its place at the press, or 0 when the pane
    /// showed at its minimum or more there (a pane that already showed under it, a pane growing in, is not pushed up).
    var floor: CGFloat = 0

    /// The pointer requests the line at `requested` (pointer space, along the axis). Where the line shows behind it,
    /// every edge drops its share of the part of the clamp's spring the pointer has passed, distance and speed alike (what
    /// is left is the same spring, scaled). The line's target is where the drag's mode rests it now: past it, the whole
    /// spring goes. False once nothing of the spring is left: the hold ends.
    func follow(_ requested: CGFloat, on screen: ScreenContentView) -> Bool { // perf-hot: 4ms motion-frame
        guard let line = line(on: screen), let target = SharedEdgeMotion.restLine(kind, axis: axis, in: screen.geometry) else { return false }
        // How far the line still springs toward its target, and how far the pointer is past where the line shows.
        let remaining = -line.left * free, lag = (requested - target - line.left) * free
        guard remaining > 0.001 else { return false }
        guard lag > 0 else { return true }
        let part = min(lag / remaining, 1)
        drop(line.left * part, line.speed * part, on: screen)
        // In a frame tick it waits for the frame's one presentation (`LayoutFrameInput`); at a release it shows now.
        screen.applyPresentation()
        return part < 1
    }

    /// Each frame after the springs step and before the frame shows (`ScreenContentView.step`): where the anchor's
    /// leftover has come closer to the line's than the floor allows (the anchor reached the line with the pane at its
    /// minimum), every edge that moves with the line takes the difference, distance and speed: from then on the line
    /// moves as the anchor does, the pane stays at its minimum, and both land together. It only ever takes the line on
    /// toward its target, never back.
    func push(on screen: ScreenContentView) { // perf-hot: 4ms motion-frame
        guard let line = line(on: screen), let anchor = anchorState(on: screen), (line.left - anchor.left) * free < floor - 0.001 else { return }
        // The line's leftover and speed become the anchor's (at the floor's distance); a line already faster keeps its speed.
        let speed = (line.speed - anchor.speed) * free < 0 ? line.speed - anchor.speed : 0
        drop(line.left - anchor.left - floor * free, speed, on: screen)
    }

    /// The anchor's leftover (its edge's distance to its target) and speed along the axis.
    private func anchorState(on screen: ScreenContentView) -> (left: CGFloat, speed: CGFloat)? {
        guard let anchor, let frame = screen.paneFrames[anchor.pane] else { return nil }
        let edges = axis == .horizontal ? SharedEdgeMotion.Edges(start: frame.x, extent: frame.width)
            : SharedEdgeMotion.Edges(start: frame.y, extent: frame.height)
        return anchor.high ? (edges.high - edges.highTarget, edges.highSpeed) : (edges.low - edges.lowTarget, edges.lowSpeed)
    }

    /// The line's leftover (its spring's distance to its target) and speed along the axis.
    private func line(on screen: ScreenContentView) -> (left: CGFloat, speed: CGFloat)? {
        guard let handle = screen.dividerFrames[kind] else { return nil }
        let spring = axis == .horizontal ? handle.x : handle.y
        return (spring.value - spring.target, spring.velocity)
    }

    /// Takes `left` and `speed` of the line's spring off every edge, each by its share.
    private func drop(_ left: CGFloat, _ speed: CGFloat, on screen: ScreenContentView) {
        for (pane, share) in panes {
            guard var frame = screen.paneFrames[pane] else { continue }
            Self.drop(left, speed, share: share, from: &frame, axis: axis)
            screen.paneFrames[pane] = frame
        }
        for (key, share) in dividers {
            guard var frame = screen.dividerFrames[key] else { continue }
            Self.drop(left, speed, share: share, from: &frame, axis: axis)
            screen.dividerFrames[key] = frame
        }
    }

    private static func drop(_ left: CGFloat, _ speed: CGFloat, share: (low: CGFloat, high: CGFloat), from frame: inout AnimatedFrame,
                             axis: SplitAxis) {
        func change(_ edges: inout SharedEdgeMotion.Edges) {
            (edges.low, edges.lowSpeed) = (edges.low - left * share.low, edges.lowSpeed - speed * share.low)
            (edges.high, edges.highSpeed) = (edges.high - left * share.high, edges.highSpeed - speed * share.high)
        }
        if axis == .horizontal {
            var edges = SharedEdgeMotion.Edges(start: frame.x, extent: frame.width)
            change(&edges)
            edges.write(start: &frame.x, extent: &frame.width)
        } else {
            var edges = SharedEdgeMotion.Edges(start: frame.y, extent: frame.height)
            change(&edges)
            edges.write(start: &frame.y, extent: &frame.height)
        }
    }
}

extension SharedEdgeClamp {
    /// The clamp of a press that caught `kind`'s line drawn at `held` (base geometry space), its anchor resting at `base`,
    /// from `screen`'s layout after the press's pass, each edge's share from `influence`; nil when the layout rests the
    /// line where it is drawn.
    init?(_ kind: DividerHandleView.Kind, axis: SplitAxis, held: CGFloat, base: CGFloat, on screen: ScreenContentView,
          influence: SharedEdgeMotion.Influence) {
        guard let rest = SharedEdgeMotion.restLine(kind, axis: axis, in: screen.baseGeometry), abs(rest - held) > 0.001 else { return nil }
        (self.kind, self.axis, free) = (kind, axis, rest > held ? 1 : -1)
        panes = [:]
        for pane in screen.paneFrames.keys {
            guard let share = influence.fractions(from: influence.caught.panes[pane], to: influence.probe.panes[pane]),
                  share.low != 0 || share.high != 0 else { continue }
            panes[pane] = share
        }
        dividers = [:]
        for key in screen.dividerFrames.keys {
            let from = SharedEdgeMotion.Influence.target(key, in: influence.caught), to = SharedEdgeMotion.Influence.target(key, in: influence.probe)
            guard let share = influence.fractions(from: from, to: to), share.low != 0 || share.high != 0 else { continue }
            dividers[key] = share
        }
        anchor = Self.anchor(kind, axis: axis, free: free, rest: rest, base: base, panes: panes, in: screen)
        if let line = line(on: screen), let anchor = anchorState(on: screen) { floor = min((line.left - anchor.left) * free, 0) }
    }

    /// The edge behind a line that springs along `free` to `rest`: where the line moves away from its anchor (resting at
    /// `base`), the anchor (a minimum from it); where it moves toward the anchor, a split's far edge (a minimum from that
    /// side). A pane edge on that place that does not move with the line, of a pane whose other edge does. Nil for a column
    /// edge moving toward its anchor (a widest share: nothing behind the line).
    private static func anchor(_ kind: DividerHandleView.Kind, axis: SplitAxis, free: CGFloat, rest: CGFloat, base: CGFloat,
                               panes: [PaneID: (low: CGFloat, high: CGFloat)], in screen: ScreenContentView) -> (pane: PaneID, high: Bool)? {
        let grows: CGFloat = rest >= base ? 1 : -1
        let place: CGFloat
        if free == grows {
            place = base
        } else if case let .split(id) = kind, let divider = screen.baseGeometry.dividers.first(where: { $0.id == id }) {
            place = grows > 0 ? (axis == .horizontal ? divider.container.maxX : divider.container.maxY)
                : (axis == .horizontal ? divider.container.minX : divider.container.minY)
        } else {
            return nil
        }
        // The anchor's edge is on the side the line moves away from.
        let high = free < 0
        for (pane, share) in panes {
            let (near, far) = high ? (share.high, share.low) : (share.low, share.high)
            guard abs(near) < 0.000_001, far > 0.000_001, let target = screen.paneFrames[pane]?.targetRect else { continue }
            let edge = axis == .horizontal ? (high ? target.maxX : target.minX) : (high ? target.maxY : target.minY)
            if abs(edge - place) <= 0.5 { return (pane, high) }
        }
        return nil
    }
}
