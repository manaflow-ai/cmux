import AppKit

/// Host mode: what this pane's pages tell their page view, and drags into and out of them (tasks 045, 050,
/// 051, 054, 061 and 234 of plans/cmux-next/chrome-parity/p01-process.md).
extension CEFPaneHost {
    /// CURSOR, TOOLTIP, DRAG_OPERATION, WHEEL_ACK or SUGGESTIONS of `browser`, one of this pane's.
    func pageViewChanged(_ change: CEFPageViewEvent, browser: Int32) {
        switch change {
        case .cursor(let cursor):
            pageCursorChanged(cursor, browser: browser)
        case .tooltip(let text):
            pageTooltipChanged(text, browser: browser)
        case .dragOperation(let operation):
            hostedPageView?.dragDestination.answered(browser: browser, operation: operation)
        case .wheelAck(let ack):
            runtime.swipeNavigation.wheelAcked(ack, browser: browser)
        case .suggestions(let event):
            let wire = CEFPaneSuggestionWire(pane: self)
            if let page = hostedPageView {
                page.suggestions.handle(event, browser: browser, wire: wire)
            } else if case .show(let rows) = event {
                wire.send(.dismiss, token: rows.token, row: 0, browser: browser)  // no page view to draw them on
            }
        }
    }

    /// The pane shows `browser` now (nil: no tab): suggestions of another browser close, and Chromium
    /// hears they were dismissed while that browser lives (task 061).
    func suggestionsFollowShownBrowser(_ browser: Int32?) {
        guard let page = hostedPageView else { return }
        page.suggestions.shownBrowserChanged(to: browser) { self.runtime.tabsByBrowser[$0] != nil }
    }

    /// `page` takes drags into the shown tab's page when the host takes drops (feature
    /// `chromiumHostDragIn`), and its page's own drag back over it when pages drag out (feature
    /// `chromiumHostDragOut`, task 051). The pane's `CEFHostView` takes the drags while the page view
    /// takes no events of its own (``ChromiumHostPageView/InputTarget/pageWindow``) and hands them to it.
    func takeHostDrags(on page: ChromiumHostPageView) {
        guard let start = runtime.hostStart, start.takesDrags || start.dragsOut else { return }
        page.takeDrags(through: CEFPaneDragWire(pane: self), outside: start.takesDrags)
        hostView.fileDrag.hostedPage = { [weak page] in page }
    }
}
