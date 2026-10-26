public import AppKit

/// The page's cursor over the page view (task 045 of plans/cmux-next/chrome-parity/p01-process.md).
/// In host mode the Chromium Host's page window never shows, so Chromium cannot set the cursor:
/// its CURSOR event becomes ``pageCursor`` and this view shows it, as Chrome's app shim view does
/// with the cursor its browser process sends (content/app_shim_remote_cocoa/
/// render_widget_host_view_cocoa.mm: `-updateCursor:`, `-resetCursorRects`).
extension ChromiumHostPageView {
    /// The page's cursor covers the visible page; with none, AppKit's.
    public override func resetCursorRects() {
        guard let shownCursor else { return super.resetCursorRects() }
        addCursorRect(visibleRect, cursor: shownCursor)
    }

    /// New cursor rects take effect only when the pointer next moves, so a cursor the page changes
    /// under a still pointer (a hover style, a drag) shows now, as `-updateCursor:` does.
    func showPageCursor() {
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        guard let shownCursor, window.isKeyWindow,
              visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        shownCursor.set()
    }

    /// The CSS name of the page's cursor ("custom" for an image), nil while the page view shows none
    /// (`debug.cef`'s `page_cursor`, chromium-host-bench.py's cursor row).
    public var pageCursorName: String? { pageCursor?.cssName }

    /// The first page view in `view`'s tree (a tab's content view holds at most one).
    public static func first(in view: NSView) -> ChromiumHostPageView? {
        if let page = view as? ChromiumHostPageView { return page }
        for subview in view.subviews {
            if let page = first(in: subview) { return page }
        }
        return nil
    }
}
