public import AppKit
import CmuxNextWakeups

/// A page moved into another view (a parked New Tab spare adopted, cx-21zkz): WebKit shows nothing
/// there until the page draws again. The page stays clear until its next frame, or
/// ``revealMovedPage()``.
extension AgentPaneView {
    /// Keeps this view's page clear until its next frame; `drawn` runs then, in the transaction that shows it.
    /// A page whose frame is never reported (a hung web process) shows after `limit` all the same.
    public func hideMovedPage(limit: Duration = .seconds(3), until drawn: @escaping () -> Void) {
        pageContent.alphaValue = 0
        // Visible: the person waits on the page this cover hides. The action holds the deadline until it runs or
        // the frame cancels it (a released MainDeadline never fires).
        let deadline = MainDeadline(owner: "newTab.moveCover.deadline", workClass: .visible, scheduler: model.deadlines)
        deadline.schedule(after: limit) { [weak self] in
            withExtendedLifetime(deadline) {}
            self?.revealMovedPage()
        }
        redraw.afterNextFrame { [weak self] in
            deadline.cancel()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.revealMovedPage()
            drawn()
            CATransaction.commit()
        }
    }

    /// Shows a page ``hideMovedPage(until:)`` keeps clear.
    public func revealMovedPage() {
        guard model.hasPainted else { return }
        pageContent.alphaValue = 1
    }
}
