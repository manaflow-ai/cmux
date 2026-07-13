import Foundation

enum TerminalNotificationScrollRestoreTarget: Equatable {
    case bottom
    case absoluteRow(Int)
}

enum TerminalNotificationScrollRestorePhase: Equatable {
    case idle
    case pending(TerminalNotificationScrollPosition)
}

private enum TerminalNotificationScrollRestoreDecision {
    case unavailable
    case waitForViewport
    case perform(TerminalNotificationScrollRestoreTarget)
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
        guard let position, position.totalRows != nil else {
            notificationScrollRestorePhase = .idle
            return false
        }
        notificationScrollRestorePhase = .pending(position)
        return retryPendingNotificationScrollRestore()
    }

    @discardableResult
    func retryPendingNotificationScrollRestore() -> Bool {
        guard case .pending(let position) = notificationScrollRestorePhase else { return false }
        switch notificationScrollRestoreDecision(position) {
        case .unavailable:
            notificationScrollRestorePhase = .idle
            return false
        case .waitForViewport:
            return true
        case .perform(let target):
            notificationScrollRestorePhase = .idle
            guard performNotificationScrollRestore(target) else {
                notificationScrollRestorePhase = .pending(position)
                return true
            }
            return true
        }
    }

    func cancelPendingNotificationScrollRestore() {
        notificationScrollRestorePhase = .idle
    }

    private func performNotificationScrollRestore(_ target: TerminalNotificationScrollRestoreTarget) -> Bool {
        allowExplicitScrollbarSync = true
        let didRestore: Bool
        switch target {
        case .bottom:
            didRestore = surfaceView.performBindingAction("scroll_to_bottom")
            if didRestore {
                userScrolledAwayFromBottom = false
            }
        case .absoluteRow(let targetTopRow):
            let currentTotalRows = Int(clamping: surfaceView.scrollbar?.total ?? 0)
            let currentVisibleRows = min(currentTotalRows, Int(clamping: surfaceView.scrollbar?.len ?? 0))
            let currentLastTopRow = currentTotalRows - currentVisibleRows
            didRestore = surfaceView.performBindingAction("scroll_to_row:\(targetTopRow)")
            if didRestore {
                userScrolledAwayFromBottom = targetTopRow < currentLastTopRow
            }
        }
        if !didRestore {
            allowExplicitScrollbarSync = false
        }
        return didRestore
    }

    private func notificationScrollRestoreDecision(
        _ position: TerminalNotificationScrollPosition
    ) -> TerminalNotificationScrollRestoreDecision {
        guard let capturedTotalRows = position.totalRows else { return .unavailable }
        if position.row <= 0 {
            return .perform(.bottom)
        }
        guard let scrollbar = surfaceView.scrollbar else { return .waitForViewport }
        let currentTotalRows = Int(clamping: scrollbar.total)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: scrollbar.len))
        guard currentVisibleRows > 0 else { return .waitForViewport }

        let normalizedCapturedTotalRows = max(0, capturedTotalRows)
        let capturedRowsBelowViewport = min(normalizedCapturedTotalRows, max(0, position.row))
        let capturedViewportBottomRow = normalizedCapturedTotalRows - capturedRowsBelowViewport

        // A newly restored terminal can report a nonzero viewport before its
        // historical rows finish replaying. Keep the anchor pending until the
        // captured viewport exists instead of permanently clamping it to the
        // partial buffer.
        guard currentTotalRows >= capturedViewportBottomRow else { return .waitForViewport }
        guard let target = notificationScrollRestoreTarget(position) else { return .waitForViewport }
        return .perform(target)
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
