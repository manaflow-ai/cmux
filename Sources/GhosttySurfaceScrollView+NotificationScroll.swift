import Foundation

enum TerminalNotificationScrollRestoreTarget: Equatable {
    case bottom
    case absoluteRow(Int)
}

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
        guard let target = notificationScrollRestoreTarget(position) else { return false }
        allowExplicitScrollbarSync = true
        let didRestore: Bool
        switch target {
        case .bottom:
            userScrolledAwayFromBottom = false
            didRestore = surfaceView.performBindingAction("scroll_to_bottom")
        case .absoluteRow(let targetTopRow):
            let currentTotalRows = Int(clamping: surfaceView.scrollbar?.total ?? 0)
            let currentVisibleRows = min(currentTotalRows, Int(clamping: surfaceView.scrollbar?.len ?? 0))
            let currentLastTopRow = currentTotalRows - currentVisibleRows
            userScrolledAwayFromBottom = targetTopRow < currentLastTopRow
            didRestore = surfaceView.performBindingAction("scroll_to_row:\(targetTopRow)")
        }
        if !didRestore {
            allowExplicitScrollbarSync = false
        }
        return didRestore
    }

    func notificationScrollRestoreTarget(
        _ position: TerminalNotificationScrollPosition?
    ) -> TerminalNotificationScrollRestoreTarget? {
        guard let position else { return nil }
        guard let capturedTotalRows = position.totalRows else { return nil }
        if position.row <= 0 {
            return .bottom
        }
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        let currentTotalRows = Int(clamping: scrollbar.total)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: scrollbar.len))
        guard currentVisibleRows > 0 else { return nil }
        let currentLastTopRow = currentTotalRows - currentVisibleRows
        let normalizedCapturedTotalRows = max(0, capturedTotalRows)
        let capturedRowsBelowViewport = min(normalizedCapturedTotalRows, max(0, position.row))
        let capturedViewportBottomRow = normalizedCapturedTotalRows - capturedRowsBelowViewport

        // Explicitly scrolled captures retain their historical viewport. Ghostty's
        // scroll_to_row action takes the absolute first visible row, with zero at
        // the top of history.
        let unclampedTopRow = max(0, capturedViewportBottomRow - currentVisibleRows)
        return .absoluteRow(min(currentLastTopRow, unclampedTopRow))
    }
}
