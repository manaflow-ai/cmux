public import AppKit

/// A page moved into another view (a parked New Tab spare adopted, cx-21zkz): WebKit shows nothing
/// there until the page draws again. The page stays clear until its next frame, or
/// ``revealMovedPage()``.
extension AgentPaneView {
    /// Keeps this view's page clear until its next frame; `drawn` runs then, in the transaction that shows it.
    public func hideMovedPage(until drawn: @escaping () -> Void) {
        pageContent.alphaValue = 0
        redraw.afterNextFrame { [weak self] in
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
