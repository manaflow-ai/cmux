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
