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
        guard let targetTopRow = notificationScrollTargetRow(position) else { return false }
        let currentTotalRows = Int(clamping: surfaceView.scrollbar?.total ?? 0)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: surfaceView.scrollbar?.len ?? 0))
        let currentLastTopRow = currentTotalRows - currentVisibleRows
        allowExplicitScrollbarSync = true
        userScrolledAwayFromBottom = targetTopRow < currentLastTopRow
        let didRestore = surfaceView.performBindingAction("scroll_to_row:\(targetTopRow)")
        if !didRestore {
            allowExplicitScrollbarSync = false
        }
        return didRestore
    }

    func notificationScrollTargetRow(_ position: TerminalNotificationScrollPosition?) -> Int? {
        guard let position else { return nil }
        guard let capturedTotalRows = position.totalRows else { return nil }
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        let currentTotalRows = Int(clamping: scrollbar.total)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: scrollbar.len))
        guard currentVisibleRows > 0 else { return nil }
        let currentLastTopRow = currentTotalRows - currentVisibleRows
        let normalizedCapturedTotalRows = max(0, capturedTotalRows)
        let capturedRowsBelowViewport = min(normalizedCapturedTotalRows, max(0, position.row))
        if capturedRowsBelowViewport == 0 {
            return currentLastTopRow
        }
        let capturedViewportBottomRow = normalizedCapturedTotalRows - capturedRowsBelowViewport

        // A bottom-pinned capture follows live output. Explicitly scrolled captures
        // retain their historical viewport. Ghostty's scroll_to_row action takes
        // the absolute first visible row, with zero at the top of history.
        let unclampedTopRow = max(0, capturedViewportBottomRow - currentVisibleRows)
        return min(currentLastTopRow, unclampedTopRow)
    }
}
