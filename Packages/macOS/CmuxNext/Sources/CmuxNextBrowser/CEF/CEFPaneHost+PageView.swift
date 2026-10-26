import AppKit

/// Host mode: what this pane's pages tell their page view, and drags into them (tasks 045 and 050 of
/// plans/cmux-next/chrome-parity/p01-process.md).
extension CEFPaneHost {
    /// CURSOR or DRAG_OPERATION of `browser`, one of this pane's.
    func pageViewChanged(_ change: CEFPageViewEvent, browser: Int32) {
        switch change {
        case .cursor(let cursor):
            pageCursorChanged(cursor, browser: browser)
        case .dragOperation(let operation):
            hostedPageView?.dragDestination.answered(browser: browser, operation: operation)
        }
    }

    /// `page` takes drags into the shown tab's page when the host takes drops (feature
    /// `chromiumHostDragIn`). The pane's `CEFHostView` takes the drags while the page view takes no
    /// events of its own (``ChromiumHostPageView/InputTarget/pageWindow``) and hands them to it.
    func takeHostDrags(on page: ChromiumHostPageView) {
        guard runtime.hostStart?.takesDrags == true else { return }
        page.takeDrags(through: CEFPaneDragWire(pane: self))
        hostView.fileDrag.hostedPage = { [weak page] in page }
    }
}
