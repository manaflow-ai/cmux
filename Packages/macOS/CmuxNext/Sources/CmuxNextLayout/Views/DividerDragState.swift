import AppKit
import CmuxNextDesign

/// A divider, column-edge or row-edge drag in progress (`ScreenContentView.activeDrag`).
struct DividerDragState {
    var kind: DividerHandleView.Kind
    var transaction: LayoutTransactionID
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
    /// (cx-piioc), and the one the divider sits on now.
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

    /// How close, in points, a split divider comes to a snap before it lands there.
    static let snapDistance: CGFloat = 8
    static func snaps(equalShare: Double?) -> [Double] {
        let thirds = [1.0 / 3, 0.5, 2.0 / 3]
        return thirds + [equalShare].compactMap { $0 }.filter { !thirds.contains($0) }
    }

    /// The snap reach for the modifiers held: none with Control, any distance with Shift.
    var snapReach: CGFloat {
        if modifiers.fine { return 0 }
        return modifiers.snap ? .infinity : Self.snapDistance
    }

    /// A split divider's ratio with the pointer at `point` (content space),
    /// snapped; entering a snap mid-drag plays the alignment haptic.
    mutating func splitRatio(at point: CGPoint, style: LayoutStyle, phase: LayoutGesturePhase) -> Double {
        let ratio = SplitGeometry.ratio(forPointer: axis == .horizontal ? point.x : point.y, grabOffset: grabOffset, container: container,
                                        axis: axis, style: style, minimumA: minimumA, minimumB: minimumB,
                                        snaps: snaps, snapDistance: snapReach)
        let landed = snaps.contains(ratio) ? ratio : nil
        if let landed, landed != snapped, phase != .ended {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        snapped = landed
        return ratio
    }
}

struct RowDragStart {
    var rows: [LayoutRow]
    var stack: RowStackGeometry
    var minimums: [RowID: CGFloat]
}
