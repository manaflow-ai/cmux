import Foundation

@MainActor
extension GhosttySurfaceScrollView {
    var notificationScrollPosition: TerminalNotificationScrollPosition? {
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        let rowFromBottom = max(0, scrollbar.total - scrollbar.offset - scrollbar.len)
        return TerminalNotificationScrollPosition(
            row: Int(clamping: rowFromBottom),
            totalRows: Int(clamping: scrollbar.total)
        )
    }

    @discardableResult
    func restoreNotificationScrollPosition(_ position: TerminalNotificationScrollPosition?) -> Bool {
        restoreNotificationScrollPosition(
            position,
            performBindingAction: surfaceView.performBindingAction
        )
    }

    @discardableResult
    func restoreNotificationScrollPosition(
        _ position: TerminalNotificationScrollPosition?,
        performBindingAction: (String) -> Bool
    ) -> Bool {
        guard let position else { return false }
        guard let scrollbar = surfaceView.scrollbar else { return false }
        let currentTotalRows = Int(clamping: scrollbar.total)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: scrollbar.len))
        let currentLastTopRow = currentTotalRows - currentVisibleRows
        let capturedTotalRows = max(0, position.totalRows ?? currentTotalRows)
        let capturedRowsBelowViewport = min(capturedTotalRows, max(0, position.row))
        let capturedViewportBottomRow = capturedTotalRows - capturedRowsBelowViewport

        // Notifications retain the viewport's bottom edge so new output does not
        // move the captured content. Ghostty's scroll_to_row action instead takes
        // the absolute first visible row, with zero at the top of history.
        let unclampedTopRow = max(0, capturedViewportBottomRow - currentVisibleRows)
        let targetTopRow = min(currentLastTopRow, unclampedTopRow)
        allowExplicitScrollbarSync = true
        userScrolledAwayFromBottom = targetTopRow < currentLastTopRow
        let didRestore = performBindingAction("scroll_to_row:\(targetTopRow)")
        if !didRestore {
            allowExplicitScrollbarSync = false
        }
        return didRestore
    }
}
