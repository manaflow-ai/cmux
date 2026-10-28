import AppKit
import CmuxNextDesign

/// The frames of one kind of view on a screen, panes or dividers: where each one rests,
/// the rect the model's geometry gives it, and the spring that carries it there while the CPU steps the
/// motion (`motion.renderServer` off, or a kind the render server does not take). A motion the render server
/// took rests here in the change's turn; where each pane sweeps on its way is the plan's
/// (`ScreenContentView.RenderTracks`) until it lands. The rest is still each spring's target: p03-rendering-022c,
/// which removes CPU stepping, keeps only the rests here.
struct LayoutFrames<Key: Hashable> {
    /// Each frame's CPU spring: its target is the rest, its value what shows.
    var springs: [Key: AnimatedFrame] = [:]
    /// Where the frames a structural change carries showed (view x), set again once `syncScroll` has moved
    /// the camera for the new layout (``settleCarried(shift:)``).
    var carried: [Key: CGFloat] = [:]

    /// Where each frame rests.
    var rests: [Key: CGRect] { springs.mapValues(\.targetRect) }

    /// The points every frame still has to travel (all four edges): the layout spring's path, for debug.motion.
    var travelLeft: CGFloat {
        springs.values.reduce(0) { total, frame in
            total + abs(frame.x.target - frame.x.value) + abs(frame.y.target - frame.y.value)
                + abs(frame.width.target - frame.width.value) + abs(frame.height.target - frame.height.value)
        }
    }

    /// The carried frames start where they showed before the change (`shift`: the camera's shift of each,
    /// where the new layout puts it).
    mutating func settleCarried(shift: (Key) -> CGFloat) {
        for (key, shown) in carried { springs[key]?.x.value = shown - shift(key) }
        carried = [:]
    }

    /// Sets `frame`'s target (opaque); without animation it snaps there. With `pass.keepsRunning` (a pointer
    /// gesture, a divider drag, without Reduce Motion) only a frame the gesture retargets snaps: a spring
    /// already running elsewhere (a close landing in another column) keeps going (M3).
    static func retarget(_ frame: inout AnimatedFrame, to target: CGRect, pass: LayoutFramePass) {
        let retargeted = frame.targetRect != target
        frame.setTarget(target, alpha: 1)
        if !pass.animated, retargeted || !pass.keepsRunning { frame.snap() }
    }
}

/// What one reconcile pass knows about where a screen's frames come from (`ScreenContentView.reconcile`).
struct LayoutFramePass {
    /// The geometry before the change and after it.
    let before: ScreenGeometry, after: ScreenGeometry
    /// Panes growing in from a split's edge (`PaneArrival.split`).
    let arrivals: [PaneID: PaneArrival]
    /// A pane that hands what it shows to the pane the change adds, and where it slides in from.
    let handoff: (pane: PaneID, slide: CGRect)?
    /// The change carries the frames it moves from where they showed; frames spring to their rests.
    let carried: Bool, animated: Bool
    /// A pointer gesture holds the springs it does not retarget (``LayoutFrames/retarget(_:to:pass:)``).
    let keepsRunning: Bool
    /// The strip camera when the change landed.
    let offset: CGFloat
    /// The panes' springs before the change, which a split's new sliver rides.
    let shownBefore: [PaneID: AnimatedFrame]

    /// Strip springs run in strip coordinates and fixed ones in the view's: a moved strip origin (a dock that
    /// came or went) or a pane changing sides (a zoom shows its pane fixed) keeps it where it showed.
    func shift(_ geometry: ScreenGeometry, _ pane: PaneID) -> CGFloat {
        geometry.scrolls(pane: pane) ? geometry.viewShift(offset: offset) : 0
    }
}

extension LayoutFrames where Key == PaneID {
    /// Sets `pane`'s spring toward its rest `target`: one it had keeps going from where it shows (carried across
    /// a moved strip origin, or restarted at a handoff's slide); a new one starts at its arrival seed, riding its
    /// neighbour's edge, or at its rest, opaque from its first frame (an arriving pane grows in, never fades).
    mutating func place(_ pane: PaneID, at target: CGRect, pass: LayoutFramePass) {
        guard var frame = springs[pane] else {
            var frame = AnimatedFrame(pass.arrivals[pane]?.seed ?? target)
            if pass.arrivals[pane] != nil { SplitMotion.ride(&frame, panes: pass.shownBefore, skipping: Set(pass.arrivals.keys)) }
            frame.setTarget(target, alpha: 1)
            springs[pane] = frame
            return
        }
        if pass.carried {
            carried[pane] = frame.x.value + pass.shift(pass.before, pane)
            frame.x.value += pass.shift(pass.before, pane) - pass.shift(pass.after, pane)
        }
        if let handoff = pass.handoff, handoff.pane == pane {
            // At its new size past the screen edge, from where it slides in.
            frame = AnimatedFrame(handoff.slide.offsetBy(dx: -pass.shift(pass.after, pane), dy: 0))
            carried[pane] = handoff.slide.minX
        }
        Self.retarget(&frame, to: target, pass: pass)
        springs[pane] = frame
    }
}

extension LayoutFrames where Key == DividerHandleView.Kind {
    /// The springs of column edges whose kind is not among `targets`: a column that changed id in place (a New
    /// Column stand-in's handoff) keeps its edge's spring under the new kind (``place(_:at:scrolls:pass:panes:renamed:)``).
    func renamedEdges(beside targets: [Key: (rect: CGRect, axis: SplitAxis)]) -> [AnimatedFrame] {
        springs.compactMap { kind, frame in
            if case .columnEdge = kind, targets[kind] == nil { return frame }
            return nil
        }
    }

    /// Sets the spring of divider `kind` (`scrolls`: with the strip) toward its rest `target`: one it had keeps
    /// going, a renamed column edge takes its old spring, and a new one starts on the edge of the pane beside it
    /// in `panes`, where that edge shows now (an even split may put it past the new pane, on the next pane's
    /// edge), moving with that edge from its first frame. An unzoom's are there at once, under the zoomed pane
    /// springing back (it ranks above them), and so are a handoff's: its added pane is in place already.
    mutating func place(_ kind: Key, at target: (rect: CGRect, axis: SplitAxis), scrolls: Bool, pass: LayoutFramePass,
                        panes: [PaneID: AnimatedFrame], renamed: inout [AnimatedFrame]) {
        if var frame = springs[kind] {
            if scrolls, pass.carried {
                carried[kind] = frame.x.value + pass.before.viewShift(offset: pass.offset)
                frame.x.value += pass.before.viewShift(offset: pass.offset) - pass.after.viewShift(offset: pass.offset)
            }
            Self.retarget(&frame, to: target.rect, pass: pass)
            springs[kind] = frame
            return
        }
        if case .columnEdge = kind,
           let index = renamed.firstIndex(where: { abs($0.targetRect.minX - target.rect.minX) < 0.5 && abs($0.targetRect.width - target.rect.width) < 0.5 }) {
            var frame = renamed.remove(at: index)
            Self.retarget(&frame, to: target.rect, pass: pass)
            springs[kind] = frame
            return
        }
        let seeded = !pass.arrivals.isEmpty && pass.handoff == nil
        let start = seeded ? SplitMotion.startShift(of: target.rect, axis: target.axis, panes: panes, skipping: Set(pass.arrivals.keys)) : nil
        let edge: CGVector = seeded ? start?.shift ?? pass.arrivals.values.first?.edgeOffset ?? .zero : .zero
        var frame = AnimatedFrame(target.rect.offsetBy(dx: edge.dx, dy: edge.dy), alpha: 1)
        frame.setTarget(target.rect, alpha: 1)
        if let velocity = start?.velocity {
            if target.axis == .horizontal { frame.x.velocity = velocity } else { frame.y.velocity = velocity }
        }
        springs[kind] = frame
    }
}
