import AppKit
import CmuxNextDesign

/// A divider, column-edge or row-edge drag in progress (`ScreenContentView.activeDrag`).
struct DividerDragState {
    var kind: DividerHandleView.Kind
    var transaction: LayoutTransactionID
    /// The drag moves edges, not whole frames (FRAME OWNER S2B, rule D: `SharedEdgeMotion`). A press that cannot hold its
    /// line while the screen moves turns it off for its drag (`DividerDrag.catchShown`), which is then the drag from
    /// before S2B: every frame it retargets snaps to its rest place.
    var sharedEdges = true
    /// The press's pass that lays out the value it caught (rule C, `DividerDrag.catchShown`): every frame keeps where
    /// it shows.
    var catching = false
    /// The press's catch (`DividerDrag.catchShown`): the value it caught, the drag's start for that key (a modifier mode
    /// that stops setting it puts it back there), and the local value the layout showed before it, if any (a release
    /// the daemon has not confirmed): a cancel sends that again, in a new transaction.
    var caughtValue: DividerDragValue?
    var replaced: DividerDragValue?
    /// A press that caught its line where the layout clamps it (rule D): while the line springs to the clamp it never
    /// shows behind the pointer (`SharedEdgeClamp.follow`).
    var clampHold: SharedEdgeClamp?
    var grabOffset: CGFloat
    var container: CGRect
    var axis: SplitAxis
    /// Minimum extents of the two sides (split) or of the column.
    var minimumA: CGFloat = 0
    var minimumB: CGFloat = 0
    /// A docked column's handle: on the right edge it grows leftward.
    var dockEdge: DockEdge?
    /// A row edge: the column's rows and their frames when the drag
    /// began (rows.md Z1).
    var rows: RowDragStart?
    /// A split's snap ratios: halves, thirds and its chain's equal share
    /// (cx-piioc), and the snap a Shift release lands on now (a split's ratio, a column edge's preset width).
    var snaps: [Double] = []
    var snapped: Double?
    /// The pointer along `axis` (content space) and its velocity in pt/s,
    /// lightly smoothed, for the release spring (`SplitMotion.seed`).
    var pointer: (position: CGFloat, time: CFTimeInterval)?
    var velocity: CGFloat = 0

    // MARK: Modifier modes (plans/cmux-next/resize-modifiers.md)

    /// The modifier keys held now.
    var modifiers = DividerDragModifiers()
    /// Where the press was along `axis` (content space), and how far the divider trails the
    /// pointer: Control moves it at a quarter speed, and letting go of Control leaves it where it
    /// is rather than jumping back under the pointer.
    var pressAt: CGFloat = 0
    var lastRaw: CGFloat?
    var pointerShift: CGFloat = 0
    /// The last window point of the drag: a modifier change with no move re-applies there.
    var lastWindowPoint: NSPoint = .zero
    /// The pointer and keys of an event that the window's next frame tick writes
    /// (`DividerDrag.applyWaiting`), and the frame ticks the drag still keeps after its last event, so a still pointer
    /// between two events does not drop the window's display link (`ScreenContentView.panTickTail`, as a strip pan).
    var waiting = false
    var ticksLeft = 0
    /// A split divider in a scrolling column: how Option pushes the columns after it.
    var push: PushResize?
    /// A split divider: its tree at the start, for Command's even sides.
    var tree: SplitNode?
    /// A column edge in the strip: the scrolling columns at the start, for Option and Command.
    var strip: StripStart?
    /// Splits and columns the drag sets now: one it stops setting goes back to its start.
    var touched: Set<DividerDragValueKey> = []
    /// The mode hint shown (`DividerDrag.showHint`).
    var hint: String?
    var hintToast: CmuxToastHandle?

    /// `point` moved along `axis` by the trail Control left: the point the divider follows.
    mutating func effective(_ point: CGPoint) -> CGPoint {
        let raw = axis == .horizontal ? point.x : point.y
        if let lastRaw, modifiers.fine { pointerShift -= (raw - lastRaw) * (1 - DividerDragModifiers.fineScale) }
        lastRaw = raw
        return axis == .horizontal ? CGPoint(x: point.x + pointerShift, y: point.y) : CGPoint(x: point.x, y: point.y + pointerShift)
    }

    /// Notes the pointer at `point`; a pointer still for 50 ms has no velocity.
    mutating func sample(_ point: CGPoint, at time: CFTimeInterval) {
        let position = axis == .horizontal ? point.x : point.y
        if let last = pointer, time > last.time {
            let instant = (position - last.position) / CGFloat(time - last.time)
            velocity = time - last.time > 0.05 ? instant : velocity * 0.4 + instant * 0.6
        }
        pointer = (position, time)
    }

    /// Velocity at release: zero when the pointer stopped before letting go.
    func releaseVelocity(at time: CFTimeInterval) -> CGFloat {
        guard let pointer, time - pointer.time <= 0.05 else { return 0 }
        return velocity
    }

    static func snaps(equalShare: Double?) -> [Double] {
        let thirds = [1.0 / 3, 0.5, 2.0 / 3]
        return thirds + [equalShare].compactMap { $0 }.filter { !thirds.contains($0) }
    }

    /// Shift without Control: the release lands on a snap (resize-modifiers.md). The drag itself follows the pointer
    /// in every mode: no snap holds the divider and none pulls it (FRAME OWNER REFACTOR KEYS).
    var landsOnSnap: Bool { modifiers.snap && !modifiers.fine }

    /// A split divider's ratio with the pointer at `point` (content space): the pointer's own, and at a Shift release
    /// the nearest snap that keeps both sides' minimums. While Shift is held, a change of the snap the release would
    /// land on plays the alignment haptic.
    mutating func splitRatio(at point: CGPoint, style: LayoutStyle, phase: LayoutGesturePhase) -> Double {
        func ratio(snapping: Bool) -> Double {
            SplitGeometry.ratio(forPointer: axis == .horizontal ? point.x : point.y, grabOffset: grabOffset, container: container,
                                axis: axis, style: style, minimumA: minimumA, minimumB: minimumB,
                                snaps: snapping ? snaps : [], snapDistance: snapping ? .infinity : 0)
        }
        let free = ratio(snapping: false)
        guard landsOnSnap else {
            snapped = nil
            return free
        }
        let landing = ratio(snapping: true)
        return land(on: snaps.contains(landing) ? landing : nil, phase: phase) ?? free
    }

    /// Notes `snap` as the one a Shift release lands on (the alignment haptic when it changes mid-drag); returns it at
    /// the release, nil before it (the drag follows the pointer).
    mutating func land(on snap: Double?, phase: LayoutGesturePhase) -> Double? {
        if let snap, snap != snapped, phase != .ended {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        snapped = snap
        return phase == .ended ? snap : nil
    }
}

struct RowDragStart {
    var rows: [LayoutRow]
    var stack: RowStackGeometry
    var minimums: [RowID: CGFloat]
}
