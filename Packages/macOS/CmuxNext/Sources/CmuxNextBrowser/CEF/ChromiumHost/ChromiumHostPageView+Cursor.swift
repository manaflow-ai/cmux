public import AppKit
import CmuxNextDesign

/// The page's cursor over the page view (task 045 of plans/cmux-next/chrome-parity/p01-process.md).
/// In host mode the Chromium Host's page window never shows, so Chromium cannot set the cursor:
/// its CURSOR event becomes ``pageCursor`` and this view shows it, as Chrome's app shim view does
/// with the cursor its browser process sends (content/app_shim_remote_cocoa/
/// render_widget_host_view_cocoa.mm: `-updateCursor:`, `-resetCursorRects`).
///
/// Chrome's view adds one cursor rect over its visible rect, and no browser UI lies over it: the
/// find bar is a widget of its own. Here cmux's find bar, prompt bar, divider grab and crash page
/// lie over the page view and the grab moves on every frame of a divider drag, so the page shows its
/// cursor in `.cursorUpdate` areas over the same pieces instead: moving them swaps
/// tracking areas and rebuilds none of the window's cursor rects. They leave out ``cursorHoles`` and
/// the crash page: the holes the in-process page window gets for the same views (``CEFHostView/occlusionRects``).
extension ChromiumHostPageView {
    // tracking-area: the cursor pieces are rects cut from the visible rect, not `.inVisibleRect`; this only moves them (the pointer area is added once, in init).
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        placeCursorAreas()
    }

    /// The pointer entered a piece of the visible page that no view covers (``cursorAreas``).
    public override func cursorUpdate(with event: NSEvent) {
        shownCursor?.set()
    }

    /// Places ``cursorAreas`` over the visible page less the views over it, none while the page shows no
    /// cursor (AppKit's then). Nothing when the pieces are the same.
    func placeCursorAreas() {
        let rects = shownCursor == nil ? [] : Self.uncovered(visibleRect, by: coveredRects)
        guard rects != cursorAreas.map(\.rect) else { return }
        for area in cursorAreas { removeTrackingArea(area) }
        cursorAreas = rects.map { rect in
            let area = NSTrackingArea(rect: rect, options: [.cursorUpdate, .activeInKeyWindow], owner: self)
            addTrackingArea(area)
            return area
        }
    }

    /// An area sets its cursor only when the pointer enters it, so a cursor the page changes under a
    /// still pointer (a hover style, a drag) shows now, as `-updateCursor:` does; never over a view
    /// that covers the page.
    func showPageCursor() {
        placeCursorAreas()
        guard let window, let shownCursor, window.isKeyWindow else { return }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(pointer), !coveredRects.contains(where: { $0.contains(pointer) }) else { return }
        shownCursor.set()
    }

    /// Where views over the page cover it, in this view's coordinates: ``cursorHoles`` and the crash page.
    var coveredRects: [CGRect] {
        guard let crashOverlay, !crashOverlay.isHidden else { return cursorHoles }
        return cursorHoles + [crashOverlay.frame]
    }

    /// `rect` less every rect of `holes`, as rects that do not overlap (none where the holes cover all of it).
    static func uncovered(_ rect: CGRect, by holes: [CGRect]) -> [CGRect] {
        holes.reduce(rect.isEmpty ? [] : [rect]) { pieces, hole in
            pieces.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(hole)
                guard !cut.isNull, !cut.isEmpty else { return [piece] }
                return [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                    CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height),
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }
    }

    /// The page's tooltip (host mode, TOOLTIP of task 054): Chrome's page view shows `SetTooltipText`
    /// with `-setToolTipAtMousePoint:`, and here cmux's themed tooltip shows it below the pointer, at
    /// once although the pointer is already over the page (``NSView/setThemedToolTipAtPointer(_:)``);
    /// nil or "" shows none. In process the page window shows Chromium's own.
    var pageTooltip: String? {
        get { themedToolTip }
        set { setThemedToolTipAtPointer(newValue) }
    }

    /// The page's tooltip text, nil while none shows (`debug.cef`'s `page_tooltip`,
    /// chromium-host-bench.py's tooltip row).
    public var pageTooltipText: String? { pageTooltip }

    /// The CSS name of the page's cursor ("custom" for an image), nil while the page view shows none
    /// (`debug.cef`'s `page_cursor`, chromium-host-bench.py's cursor row).
    public var pageCursorName: String? { pageCursor?.cssName }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// A pointer move over this view reaches the page's renderer: it takes the page's input and has a
    /// route to the Chromium Host (`debug.mouse`'s page `move`).
    public var takesPagePointer: Bool { inputTarget == .view && sink != nil }
    #endif

    /// The first page view in `view`'s tree (a tab's content view holds at most one).
    public static func first(in view: NSView) -> ChromiumHostPageView? {
        if let page = view as? ChromiumHostPageView { return page }
        for subview in view.subviews {
            if let page = first(in: subview) { return page }
        }
        return nil
    }
}
