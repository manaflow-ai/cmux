import CmuxNextDesign
import CoreGraphics

/// FRAME OWNER REFACTOR S2B, rule D's clamp: a press whose drawn line the layout does not rest there (the anchor's rest
/// place leaves the pane less than its minimum) springs the line from where it is drawn to the clamp. Each edge carries
/// its share of that spring (its fraction of the line's move, `SharedEdgeMotion.Influence`; springs are linear, so its
/// part is always that share of the line's leftover), and a drag move keeps it (each edge moves by its target's change).
/// The pointer still holds the line: where the line shows behind the pointer, ``follow(_:on:)`` drops the part of that
/// spring the pointer has passed, so the line shows under the pointer and the rest of the spring takes it on toward its
/// target. The press checks that no pane can show a negative size with any part of it dropped
/// (`SharedEdgeMotion.mayShowNegativeSize`, `clampLeftover`).
struct SharedEdgeClamp {
    var kind: DividerHandleView.Kind
    var axis: SplitAxis
    /// +1 when the line springs toward growing coordinates (its target is past where it was drawn that way), -1 else.
    var free: CGFloat
    /// How far each frame's low and high edges move along the axis for each point the line moves; frames it moves only.
    var panes: [PaneID: (low: CGFloat, high: CGFloat)]
    var dividers: [DividerHandleView.Kind: (low: CGFloat, high: CGFloat)]

    /// The pointer requests the line at `requested` (pointer space, along the axis). Where the line shows behind it,
    /// every edge drops its share of the part of the clamp's spring the pointer has passed, distance and speed alike (what
    /// is left is the same spring, scaled). The line's target is where the drag's mode rests it now: past it, the whole
    /// spring goes. False once nothing of the spring is left: the hold ends.
    func follow(_ requested: CGFloat, on screen: ScreenContentView) -> Bool { // perf-hot: 4ms motion-frame
        guard let handle = screen.dividerFrames[kind], let target = SharedEdgeMotion.restLine(kind, axis: axis, in: screen.geometry)
        else { return false }
        let spring = axis == .horizontal ? handle.x : handle.y
        let (left, speed) = (spring.value - spring.target, spring.velocity)
        // How far the line still springs toward its target, and how far the pointer is past where the line shows.
        let remaining = -left * free, lag = (requested - target - left) * free
        guard remaining > 0.001 else { return false }
        guard lag > 0 else { return true }
        let part = min(lag / remaining, 1)
        drop(left * part, speed * part, on: screen)
        return part < 1
    }

    /// Takes `left` and `speed` of the line's spring off every edge, each by its share, and shows it.
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
    }
}
