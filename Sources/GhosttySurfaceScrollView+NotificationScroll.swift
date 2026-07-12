import CmuxTerminalCore
import Foundation

@MainActor
extension GhosttySurfaceScrollView {
    var notificationScrollPosition: TerminalNotificationScrollPosition? {
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        guard let anchor = TerminalScrollbackViewportAnchor(scrollbar: scrollbar) else { return nil }
        return TerminalNotificationScrollPosition(
            row: anchor.rowsBelowViewport,
            totalRows: anchor.capturedTotalRows
        )
    }

    @discardableResult
    func restoreNotificationScrollPosition(_ position: TerminalNotificationScrollPosition?) -> Bool {
        guard let position else { return false }
        pendingNotificationScrollPosition = position
        return restorePendingNotificationScrollPositionIfReady()
    }

    @discardableResult
    func restorePendingNotificationScrollPositionIfReady() -> Bool {
        guard let position = pendingNotificationScrollPosition else { return false }
        guard let scrollbar = surfaceView.scrollbar else { return false }
        let capturedTotalRows = position.totalRows ?? Int(clamping: scrollbar.total)
        let anchor = TerminalScrollbackViewportAnchor(
            rowsBelowViewport: position.row,
            capturedTotalRows: capturedTotalRows
        )
        guard let targetTopRow = anchor.topRow(in: scrollbar) else { return false }
        let currentLastTopRow = Int(clamping: scrollbar.total - min(scrollbar.total, scrollbar.len))
        allowExplicitScrollbarSync = true
        userScrolledAwayFromBottom = targetTopRow < currentLastTopRow
        let bindingAction = targetTopRow == currentLastTopRow
            ? "scroll_to_bottom"
            : "scroll_to_row:\(targetTopRow)"
        let didRestore = surfaceView.performBindingAction(bindingAction)
        if didRestore {
            pendingNotificationScrollPosition = nil
        } else {
            allowExplicitScrollbarSync = false
        }
        return didRestore
    }
}
