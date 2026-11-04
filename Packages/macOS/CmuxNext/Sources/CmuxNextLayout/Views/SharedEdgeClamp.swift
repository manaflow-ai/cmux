import CmuxNextDesign
import CoreGraphics

/// FRAME OWNER REFACTOR S2B, rule D's clamp: a press whose drawn line the layout does not rest there (the anchor's rest
/// place leaves the pane less than its minimum) springs the line from where it is drawn to the clamp. Each edge then
/// carries its share of that spring (its fraction of the line's move, `SharedEdgeMotion.Influence`), and a drag move
/// keeps it (each edge moves by its target's change). Once the pointer passes the clamp the drag sets the line again,
/// so the spring must end there (``release(on:)``): kept, the line would trail the pointer and move under a still one.
struct SharedEdgeClamp {
    var kind: DividerHandleView.Kind
    var axis: SplitAxis
    /// Where the layout rests the line, in the drag's pointer space along the axis (`ScreenContentView.geometry`).
    var clamp: CGFloat
    /// +1 when a requested line past the clamp in growing coordinates is free of it, -1 when one in falling ones is.
    var free: CGFloat
    /// How far each frame's low and high edges move along the axis for each point the line moves; frames it moves only.
    var panes: [PaneID: (low: CGFloat, high: CGFloat)]
    var dividers: [DividerHandleView.Kind: (low: CGFloat, high: CGFloat)]

    /// Whether the line the drag requests at `requested` (pointer space, along the axis) is past the clamp.
    func frees(_ requested: CGFloat) -> Bool { (requested - clamp) * free >= 0 }

    /// The pointer passed the clamp: every edge drops its share of what is left of the clamp's spring (the line's
    /// distance to its target and its speed), so the line goes where the pointer puts it, and stays there.
    func release(on screen: ScreenContentView) {
        guard let handle = screen.dividerFrames[kind] else { return }
        let spring = axis == .horizontal ? handle.x : handle.y
        let (left, speed) = (spring.value - spring.target, spring.velocity)
        guard left != 0 || speed != 0 else { return }
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
        // In a frame tick it waits for the frame's one presentation (`LayoutFrameInput`); at a release it shows now.
        screen.applyPresentation()
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
    /// The clamp of a press that caught `kind`'s line drawn at `held` (base geometry space), from `screen`'s layout after
    /// the press's pass, each edge's share from `influence`; nil when the layout rests the line where it is drawn.
    init?(_ kind: DividerHandleView.Kind, axis: SplitAxis, held: CGFloat, on screen: ScreenContentView, influence: SharedEdgeMotion.Influence) {
        guard let rest = SharedEdgeMotion.restLine(kind, axis: axis, in: screen.baseGeometry),
              let restInPointerSpace = SharedEdgeMotion.restLine(kind, axis: axis, in: screen.geometry), abs(rest - held) > 0.001 else { return nil }
        (self.kind, self.axis, clamp, free) = (kind, axis, restInPointerSpace, rest > held ? 1 : -1)
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
    }
}
