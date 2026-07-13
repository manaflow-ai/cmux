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
        guard let position else {
            clearPendingNotificationScrollRestore()
            return false
        }

        switch notificationScrollRestoreState {
        case .replaying(let expectedBoundary, _):
            notificationScrollRestoreState = .replaying(
                expectedBoundary: expectedBoundary,
                pendingPosition: position
            )
            return false
        case .awaitingPostReplayGeometry:
            notificationScrollRestoreState = .awaitingPostReplayGeometry(
                position: position,
                attemptsRemaining: 2
            )
            return false
        case .inactive, .awaitingInitialGeometry:
            notificationScrollRestoreState = .awaitingInitialGeometry(
                position: position,
                attemptsRemaining: 2
            )
        }
        return restorePendingNotificationScrollPositionIfReady()
    }

    @discardableResult
    func restorePendingNotificationScrollPositionIfReady() -> Bool {
        let position: TerminalNotificationScrollPosition
        let attemptsRemaining: Int
        let isPostReplayGeometry: Bool
        switch notificationScrollRestoreState {
        case .inactive, .replaying:
            return false
        case .awaitingInitialGeometry(let pendingPosition, let pendingAttempts):
            position = pendingPosition
            attemptsRemaining = pendingAttempts
            isPostReplayGeometry = false
        case .awaitingPostReplayGeometry(let pendingPosition, let pendingAttempts):
            position = pendingPosition
            attemptsRemaining = pendingAttempts
            isPostReplayGeometry = true
        }

        guard attemptsRemaining > 0 else {
            clearPendingNotificationScrollRestore()
            return false
        }
        guard let scrollbar = surfaceView.scrollbar else { return false }
        let visibleRows = min(scrollbar.total, scrollbar.len)
        guard visibleRows > 0 else { return false }
        let capturedTotalRows = position.totalRows ?? Int(clamping: scrollbar.total)
        let anchor = TerminalScrollbackViewportAnchor(
            rowsBelowViewport: position.row,
            capturedTotalRows: capturedTotalRows
        )
        guard let targetTopRow = anchor.topRow(in: scrollbar) else {
            clearPendingNotificationScrollRestore()
            return false
        }
        let currentLastTopRow = Int(clamping: scrollbar.total - min(scrollbar.total, scrollbar.len))
        let previousUserScrolledAwayFromBottom = userScrolledAwayFromBottom
        allowExplicitScrollbarSync = true
        userScrolledAwayFromBottom = targetTopRow < currentLastTopRow
        let bindingAction = targetTopRow == currentLastTopRow
            ? "scroll_to_bottom"
            : "scroll_to_row:\(targetTopRow)"
        let remainingAfterAttempt = attemptsRemaining - 1
        let didRestore = surfaceView.performBindingAction(bindingAction)
        if didRestore {
            clearPendingNotificationScrollRestore()
        } else {
            allowExplicitScrollbarSync = false
            userScrolledAwayFromBottom = previousUserScrolledAwayFromBottom
            if remainingAfterAttempt == 0 {
                clearPendingNotificationScrollRestore()
            } else if isPostReplayGeometry {
                notificationScrollRestoreState = .awaitingPostReplayGeometry(
                    position: position,
                    attemptsRemaining: remainingAfterAttempt
                )
            } else {
                notificationScrollRestoreState = .awaitingInitialGeometry(
                    position: position,
                    attemptsRemaining: remainingAfterAttempt
                )
            }
        }
        return didRestore
    }

    func clearPendingNotificationScrollRestore() {
        if case .replaying(let expectedBoundary, _) = notificationScrollRestoreState {
            notificationScrollRestoreState = .replaying(
                expectedBoundary: expectedBoundary,
                pendingPosition: nil
            )
        } else {
            notificationScrollRestoreState = .inactive
        }
    }

    func cancelPendingNotificationScrollRestoreForUserInput() {
        guard notificationScrollRestoreState.pendingPosition != nil else { return }
        clearPendingNotificationScrollRestore()
    }

    func sessionScrollbackReplayDidBegin(expectedBoundary: String) {
        notificationScrollRestoreState = .replaying(
            expectedBoundary: expectedBoundary,
            pendingPosition: notificationScrollRestoreState.pendingPosition
        )
    }

    @discardableResult
    func sessionScrollbackReplayDidReceiveBoundary(_ boundary: String) -> Bool {
        guard case .replaying(let expectedBoundary, let pendingPosition) = notificationScrollRestoreState,
              boundary == expectedBoundary else {
            return false
        }
        guard let pendingPosition else {
            notificationScrollRestoreState = .inactive
            return true
        }
        notificationScrollRestoreState = .awaitingPostReplayGeometry(
            position: pendingPosition,
            attemptsRemaining: 2
        )
        return true
    }

    var hasPendingNotificationScrollRestore: Bool {
        notificationScrollRestoreState.pendingPosition != nil
    }

    func terminalSurfaceDidReceiveExplicitInput() {
        cancelPendingNotificationScrollRestoreForUserInput()
    }
}
