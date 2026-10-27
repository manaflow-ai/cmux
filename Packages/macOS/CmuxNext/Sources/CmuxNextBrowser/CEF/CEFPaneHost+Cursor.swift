import AppKit

/// Host mode: the page cursor of each browser in this pane's Chromium window, shown on
/// ``hostedPageView`` while its tab is the shown one (task 045 of
/// plans/cmux-next/chrome-parity/p01-process.md). Chrome keeps a cursor per page view and shows
/// the one of the view under the pointer (content/browser/renderer_host/cursor_manager.cc); here
/// the pane's tabs share one page view, so the pane keeps each browser's last cursor and shows the
/// shown tab's. A renderer sends its cursor only when it changes, so a tab shown again would
/// otherwise keep the cursor of the tab before it.
extension CEFPaneHost {
    /// CURSOR of `browser`: kept, and shown at once when its tab is the shown one.
    func pageCursorChanged(_ cursor: CEFPageCursor, browser: Int32) {
        pageCursors[browser] = cursor
        if pageCursors.count > tabs.count { forgetClosedPageCursors() }
        if visibleTab?.browserID == browser { hostedPageView?.pageCursor = cursor }
    }

    /// `browser`'s tab shows: its last cursor, the arrow until its page set one, and no tooltip
    /// (the tab before's text is not this page's; its page sends a new one on the next hover). In
    /// process the page window shows Chromium's cursor and tooltip itself.
    func showPageCursor(of browser: Int32) {
        guard isHostMode else { return }
        hostedPageView?.pageCursor = pageCursors[browser] ?? .arrow
        hostedPageView?.pageTooltip = nil
    }

    /// TOOLTIP of `browser` (task 054): shown on the page view while its tab is the shown one. A
    /// renderer sends its tooltip on each hover change, so nothing is kept for a hidden tab.
    func pageTooltipChanged(_ text: String, browser: Int32) {
        guard visibleTab?.browserID == browser else { return }
        hostedPageView?.pageTooltip = text
    }

    /// Drops the cursors of browsers no tab of this pane has any more (closed, or moved away).
    private func forgetClosedPageCursors() {
        let live = Set(tabs.compactMap(\.browserID))
        pageCursors = pageCursors.filter { live.contains($0.key) }
    }
}
