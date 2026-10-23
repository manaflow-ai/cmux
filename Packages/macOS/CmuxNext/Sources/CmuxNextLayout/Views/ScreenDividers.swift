import AppKit

/// Divider surfaces of one screen (cx-ww20), kept out of `ScreenContentView`
/// so the view stays one owner of frames: the hover of its handles, the hit
/// areas and drawn lines the overlay reports, and the column a resize drag
/// anchors the strip on.
@MainActor
struct ScreenDividers {
    let screen: ScreenContentView

    /// Hover is a function of where the pointer is now and where the handles
    /// are now, recomputed whenever either changes (a tracking event, a page
    /// catcher panel's event, every presentation pass including strip and
    /// row scrolls, key-window changes). The topmost visible handle under the
    /// pointer is hovered; every other one is not.
    func refreshHover() {
        let hovered = hoveredHandle()
        for view in screen.dividerViews.values { view.setHovered(view === hovered) }
    }

    private func hoveredHandle() -> DividerHandleView? {
        // During a drag only the dragged handle shows (its line is the drag's).
        if let drag = screen.activeDrag { return screen.dividerViews[drag.kind] }
        guard let window = screen.window, !screen.isHiddenOrHasHiddenAncestor,
              let point = screen.context.hoverPointer(window).map({ screen.convert($0, from: nil) }),
              screen.bounds.intersection(screen.visibleRect).contains(point) else { return nil }
        let hit = screen.subviews.reversed().lazy.compactMap { $0 as? DividerHandleView }.first {
            // Where it shows its cursor: not the part under a dock or past its area's window.
            !$0.isHidden && $0.alphaValue > 0.01 && screen.convert($0.cursorRectInBounds, from: $0).contains(point)
        }
        guard let hit, screen.context.hoverReachesWindow(window) else { return nil }
        return hit
    }

    /// Divider hit areas on screen, in the screen's coordinates. They take the
    /// mouse but draw only their thin line, so content drawn above the window
    /// (a Chromium page) keeps drawing under them.
    var mouseAreas: [LayoutMouseArea] {
        screen.dividerViews.compactMap { kind, view in
            guard !view.isHidden, view.alphaValue > 0.01 else { return nil }
            let rect = uncovered(screen.convert(view.cursorRectInBounds, from: view).intersection(screen.bounds))
            guard !rect.isNull, !rect.isEmpty else { return nil }
            return LayoutMouseArea(id: kind.mouseAreaID, rect: rect, resizesColumns: view.axis == .horizontal)
        }.sorted { $0.id < $1.id }
    }

    /// The dividers' currently drawn lines, in the screen's coordinates:
    /// native UI that Chromium pages leave uncovered (they sit in the gap
    /// between panes). A transparent edge handle at rest leaves no hole;
    /// hovering or dragging it makes the line part of the overlay again.
    var lineRects: [CGRect] {
        screen.dividerViews.values.compactMap { view in
            guard !view.isHidden, view.alphaValue > 0.01, view.isLineVisible else { return nil }
            // Cut where its cursor stops too (DividerHandleView `cursorClip`): no hole through a dock.
            let line = view.lineFrameInSuperview.intersection(screen.bounds)
            let rect = uncovered(view.cursorClip.map { line.intersection($0) } ?? line)
            return rect.isNull || rect.isEmpty ? nil : rect
        }.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    /// `rect` less what a zooming or unzooming pane shows over it: the dividers are under that pane
    /// (`ScreenContentView.rank`), so its Chromium page gets no hole and no click catcher there.
    private func uncovered(_ rect: CGRect) -> CGRect {
        guard let pane = screen.zoomMotion.pane, let host = screen.context.hosts[pane], host.superview === screen, !rect.isNull else { return rect }
        let cover = host.frame
        if cover.insetBy(dx: -0.5, dy: -0.5).contains(rect) { return .null }
        return rect.remainder(outside: cover)
    }

    /// The strip column under a resize drag: the camera keeps it in place, so
    /// its leading edge stays and its edge follows the pointer. Nil for a
    /// docked column (it does not scroll) and when no drag runs.
    var dragAnchorColumn: ColumnID? {
        guard let drag = screen.activeDrag, drag.dockEdge == nil else { return nil }
        switch drag.kind {
        case let .columnEdge(column), let .rowEdge(column, _): return column
        case let .split(split):
            return screen.layout.columns.first { column in
                column.root.ratio(of: split) != nil || column.rows.contains { $0.root.ratio(of: split) != nil }
            }?.id
        }
    }
}

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

    /// A split divider's ratio with the pointer at `point` (content space),
    /// snapped; entering a snap mid-drag plays the alignment haptic.
    mutating func splitRatio(at point: CGPoint, style: LayoutStyle, phase: LayoutGesturePhase) -> Double {
        let ratio = SplitGeometry.ratio(forPointer: axis == .horizontal ? point.x : point.y, grabOffset: grabOffset, container: container,
                                        axis: axis, style: style, minimumA: minimumA, minimumB: minimumB,
                                        snaps: snaps, snapDistance: Self.snapDistance)
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
