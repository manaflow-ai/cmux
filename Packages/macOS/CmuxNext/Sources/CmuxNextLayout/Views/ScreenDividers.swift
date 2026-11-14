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
    /// The same handle shows the resize cursor (`ScreenDividerPointer`): a screen that hid under
    /// the pointer gives the cursor back here too. `event` is the pointer event that asked.
    func refreshHover(event: NSEvent? = nil) {
        let pointer = screen.window.flatMap { screen.context.hoverPointer($0) }
        let hovered = hoveredHandle(pointer: pointer)
        for view in screen.dividerViews.values { view.setHovered(view === hovered) }
        screen.dividerPointer.show(hovered, in: screen, pointer: pointer, event: event)
    }

    private func hoveredHandle(pointer: NSPoint?) -> DividerHandleView? {
        // During a drag only the dragged handle shows (its line is the drag's).
        if let drag = screen.activeDrag { return screen.dividerViews[drag.kind] }
        guard let window = screen.window, !screen.isHiddenOrHasHiddenAncestor,
              let pointer, case let point = screen.convert(pointer, from: nil),
              screen.bounds.intersection(screen.visibleRect).contains(point) else { return nil }
        let hit = screen.subviews.reversed().lazy.compactMap { $0 as? DividerHandleView }.first {
            // Where it shows its cursor: not the part under a dock or past its area's window.
            !$0.isHidden && $0.alphaValue > 0.01 && screen.convert($0.cursorRectInBounds, from: $0).contains(point)
        }
        guard let hit, screen.context.hoverReaches(window, pointer: pointer) else { return nil }
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
        screen.dividerViews.values.flatMap { view -> [CGRect] in
            guard !view.isHidden, view.alphaValue > 0.01, view.isLineVisible else { return [] }
            // Cut where its cursor stops too (DividerHandleView `cursorClip`): no hole through a dock.
            let line = view.lineFrameInSuperview.intersection(screen.bounds)
            return uncoveredPieces(view.cursorClip.map { line.intersection($0) } ?? line)
        }.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    /// `rect` less what a zooming or unzooming pane shows over it: the dividers are under that pane
    /// (`ScreenContentView.rank`), so its Chromium page gets no click catcher there. One rect: a catcher is one panel.
    private func uncovered(_ rect: CGRect) -> CGRect {
        guard let cover = zoomCover, !rect.isNull else { return rect }
        if cover.insetBy(dx: -0.5, dy: -0.5).contains(rect) { return .null }
        return rect.remainder(outside: cover)
    }

    /// `rect` less what a zooming or unzooming pane shows over it, in as many pieces as that leaves: its Chromium page
    /// gets no line hole anywhere under it. A pane springing back into the middle of a longer line (a middle row beside
    /// a column, a middle column over a row) leaves a piece on each side; one rect for both cut the whole line through
    /// the page, which drew the split over the zoomed pane for the unzoom's frames (Lawrence 2026-11-12).
    private func uncoveredPieces(_ rect: CGRect) -> [CGRect] {
        guard !rect.isNull, !rect.isEmpty else { return [] }
        guard let cover = zoomCover else { return [rect] }
        return rect.pieces(outside: cover)
    }

    /// The frame of the pane a zoom or an unzoom springs, which shows above every divider until it lands.
    private var zoomCover: CGRect? {
        guard let pane = screen.zoomMotion.pane, let host = screen.context.hosts[pane], host.superview === screen else { return nil }
        return host.frame
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

extension CGRect {
    /// This rect less `cover`, as up to four rects (the bands above and below `cover`, then the parts left and right
    /// of it between them); none when `cover` takes it all, itself when they do not overlap. Pieces under half a point
    /// across are dropped.
    func pieces(outside cover: CGRect) -> [CGRect] {
        let shared = intersection(cover)
        guard !shared.isNull, shared.width > 0.5, shared.height > 0.5 else { return [self] }
        let candidates = [
            CGRect(x: minX, y: minY, width: width, height: shared.minY - minY),
            CGRect(x: minX, y: shared.maxY, width: width, height: maxY - shared.maxY),
            CGRect(x: minX, y: shared.minY, width: shared.minX - minX, height: shared.height),
            CGRect(x: shared.maxX, y: shared.minY, width: maxX - shared.maxX, height: shared.height),
        ]
        return candidates.filter { $0.width > 0.5 && $0.height > 0.5 }
    }
}
