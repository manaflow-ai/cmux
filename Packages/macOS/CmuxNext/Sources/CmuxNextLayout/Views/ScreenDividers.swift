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
    /// pointer is hovered; every other one is not. `event`: the handle enter or
    /// exit being handled, whose own point is the pointer.
    func refreshHover(at event: NSEvent? = nil) {
        let hovered = hoveredHandle(at: event)
        for view in screen.dividerViews.values { view.setHovered(view === hovered) }
    }

    private func hoveredHandle(at event: NSEvent?) -> DividerHandleView? {
        // During a drag only the dragged handle shows (its line is the drag's).
        if let drag = screen.activeDrag { return screen.dividerViews[drag.kind] }
        // visibility-walk-allow: the hover hit test: a hidden screen's handles take no hover
        guard let window = screen.window, !screen.isHiddenOrHasHiddenAncestor,
              let windowPoint = screen.context.hoverPointer(window, event) else { return nil }
        let point = screen.convert(windowPoint, from: nil)
        guard screen.bounds.intersection(screen.visibleRect).contains(point) else { return nil }
        let hit = screen.stackedSubviews.reversed().lazy.compactMap { $0 as? DividerHandleView }.first {
            // Where it shows its cursor: not the part under a dock or past its area's window. A handle on a
            // render-server spring has its rest frame but shows elsewhere until it lands: its landing hovers it.
            !$0.isHidden && !$0.isOnRenderSpring && $0.alphaValue > 0.01 && shown($0.cursorRectInBounds, of: $0).contains(point)
        }
        guard let hit, screen.context.hoverReachesWindow(window, windowPoint) else { return nil }
        return hit
    }

    /// Places every handle at the rect its spring presents with the strip camera at `strip`, on the pixel
    /// grid (``place(_:_:at:alpha:strip:uncovered:force:)``). Returns whether a handle changed. O(handles); a
    /// handle whose frame, alpha and clips are as they were is not touched.
    @discardableResult
    func place(strip: CGFloat, scale: CGFloat, uncovered: CGRect, force: Bool) -> Bool { // perf-hot: 4ms motion-frame
        var changed = force
        for (kind, frame) in screen.dividerFrames {
            guard let view = screen.dividerViews[kind] else { continue }
            let placed = screen.shownRect(frame.rect, of: kind, strip: strip, scale: scale)
            if place(view, kind, at: placed, alpha: frame.alpha.value, strip: strip, uncovered: uncovered, force: force) { changed = true }
        }
        return changed
    }

    /// Places `view` at `placed` with `alpha`, in the screen's coordinates, laid out with the strip camera
    /// at `strip`; its hidden state and cursor clip follow from the frame, the screen's `uncovered` rect
    /// (``ScreenContentView/uncoveredRect``) and its scroll area's laid-out window. Every pass that places
    /// a handle comes here: each presentation, a render-server spring's start (its rest frame) and its
    /// landing. Returns whether anything changed; `force` re-places a handle that looks unchanged (a style
    /// or structural change).
    @discardableResult
    func place(_ view: DividerHandleView, _ kind: DividerHandleView.Kind, at placed: CGRect, alpha: CGFloat,
               strip: CGFloat, uncovered: CGRect, force: Bool) -> Bool {
        let scrolls = screen.scrolls(kind)
        let shownArea = screen.areaWindow(of: kind, strip: strip), clips: [CGRect?] = [uncovered, shownArea]
        // A strip divider under a docked column must not take its clicks, nor one scrolled out of its area.
        // In its area's container the container's clip and frame stop it there instead, wherever a pan
        // on the container (which lays nothing out) moves it.
        let docked = scrolls && !screen.geometry.dock.isEmpty
        let inAreaContainer = (view.superview as? ScrollerPanContainerView).map { $0.scroller.isArea && $0.clipsSubviews } ?? false
        let hidden = (docked && placed.intersection(uncovered).width < 0.5)
            || (!inAreaContainer && shownArea.map { !$0.contains(CGPoint(x: placed.midX, y: placed.midY)) } == true)
        guard force || view.frame != placed || view.alphaValue != alpha || view.placedClips != clips
            || view.isHidden != hidden else { return false }
        if view.frame != placed { view.frame = placed }
        if view.alphaValue != alpha { view.alphaValue = alpha }
        view.placedClips = clips
        if view.isHidden != hidden { view.isHidden = hidden }
        // Shown, its cursor and click catcher still stop at a dock and at its area's window.
        var pointerClip: CGRect? = docked ? uncovered : nil
        if let area = shownArea { pointerClip = pointerClip.map { $0.intersection(area) } ?? area }
        view.cursorClip = pointerClip
        return true
    }

    /// Divider hit areas on screen, in the screen's coordinates. They take the
    /// mouse but draw only their thin line, so content drawn above the window
    /// (a Chromium page) keeps drawing under them.
    var mouseAreas: [LayoutMouseArea] {
        screen.dividerViews.compactMap { kind, view in
            guard !view.isHidden, view.alphaValue > 0.01 else { return nil }
            let rect = uncovered(shown(view.cursorRectInBounds, of: view).intersection(screen.bounds))
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
            let moved = screen.panTranslation(of: view)
            let line = view.lineFrameInSuperview.offsetBy(dx: moved.dx, dy: moved.dy).intersection(screen.bounds)
            let rect = uncovered(view.cursorClip.map { line.intersection($0) } ?? line)
            return rect.isNull || rect.isEmpty ? nil : rect
        }.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    /// `rect` (`view`'s coordinates) in the screen's, where it shows: a pan on the strip's motion
    /// container, or a row's or area's, moves it by the translation, which `convert` does not see.
    private func shown(_ rect: CGRect, of view: DividerHandleView) -> CGRect {
        let moved = screen.panTranslation(of: view)
        return screen.convert(rect, from: view).offsetBy(dx: moved.dx, dy: moved.dy)
    }

    /// `rect` less what a zooming or unzooming pane shows over it: the dividers are under that pane
    /// (`ScreenContentView.rank`), so its Chromium page gets no hole and no click catcher there.
    private func uncovered(_ rect: CGRect) -> CGRect {
        guard let pane = screen.zoomMotion.pane, let host = screen.context.hosts[pane], screen.holds(host), !rect.isNull else { return rect }
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
