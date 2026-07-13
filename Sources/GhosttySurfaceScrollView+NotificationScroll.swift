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
        case .armed(let expectedStartBoundary, let expectedEndBoundary, _, _):
            notificationScrollRestoreState = .armed(
                expectedStartBoundary: expectedStartBoundary,
                expectedEndBoundary: expectedEndBoundary,
                pendingPosition: position,
                attemptsRemaining: 2
            )
        case .replaying(let expectedBoundary, _):
            notificationScrollRestoreState = .replaying(
                expectedBoundary: expectedBoundary,
                pendingPosition: position
            )
            return false
        case .awaitingPostReplayGeometry:
            notificationScrollRestoreState = .awaitingPostReplayGeometry(
                position: position,
                attemptsRemaining: 2,
                provisionalTopRow: nil
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
    func restorePendingNotificationScrollPositionIfReady(
        isPostReplayGeometryUpdate: Bool = false
    ) -> Bool {
        let position: TerminalNotificationScrollPosition
        let attemptsRemaining: Int
        let isPostReplayGeometry: Bool
        let provisionalTopRow: Int?
        switch notificationScrollRestoreState {
        case .inactive, .armed, .replaying:
            return false
        case .awaitingInitialGeometry(let pendingPosition, let pendingAttempts):
            position = pendingPosition
            attemptsRemaining = pendingAttempts
            isPostReplayGeometry = false
            provisionalTopRow = nil
        case .awaitingPostReplayGeometry(
            let pendingPosition,
            let pendingAttempts,
            let pendingProvisionalTopRow
        ):
            position = pendingPosition
            attemptsRemaining = pendingAttempts
            isPostReplayGeometry = true
            provisionalTopRow = pendingProvisionalTopRow
        }

        guard attemptsRemaining > 0 else {
            clearPendingNotificationScrollRestore()
            return false
        }
        guard let scrollbar = surfaceView.scrollbar else { return false }
        let visibleRows = min(scrollbar.total, scrollbar.len)
        guard visibleRows > 0 else { return false }
        // Legacy anchors have no captured total, so stale boundary-time geometry
        // cannot distinguish the saved viewport from a partial replay snapshot.
        if isPostReplayGeometry,
           position.totalRows == nil,
           !isPostReplayGeometryUpdate {
            return false
        }
        let capturedTotalRows = position.totalRows ?? Int(clamping: scrollbar.total)
        let anchor = TerminalScrollbackViewportAnchor(
            rowsBelowViewport: position.row,
            capturedTotalRows: capturedTotalRows
        )
        guard let targetTopRow = anchor.topRow(in: scrollbar) else {
            if !isPostReplayGeometry {
                clearPendingNotificationScrollRestore()
            }
            return false
        }
        // The end boundary is ordered with PTY bytes, but renderer geometry can
        // arrive later. A matching update confirms the successful provisional
        // action without issuing the same binding a second time.
        if isPostReplayGeometryUpdate,
           provisionalTopRow == targetTopRow {
            clearPendingNotificationScrollRestore()
            return true
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
            if isPostReplayGeometry, !isPostReplayGeometryUpdate {
                notificationScrollRestoreState = .awaitingPostReplayGeometry(
                    position: position,
                    attemptsRemaining: attemptsRemaining,
                    provisionalTopRow: targetTopRow
                )
            } else {
                clearPendingNotificationScrollRestore()
            }
        } else {
            allowExplicitScrollbarSync = false
            userScrolledAwayFromBottom = previousUserScrolledAwayFromBottom
            if remainingAfterAttempt == 0 {
                clearPendingNotificationScrollRestore()
            } else if isPostReplayGeometry {
                notificationScrollRestoreState = .awaitingPostReplayGeometry(
                    position: position,
                    attemptsRemaining: remainingAfterAttempt,
                    provisionalTopRow: provisionalTopRow
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
        if case .armed(let expectedStartBoundary, let expectedEndBoundary, _, _) =
            notificationScrollRestoreState {
            notificationScrollRestoreState = .armed(
                expectedStartBoundary: expectedStartBoundary,
                expectedEndBoundary: expectedEndBoundary,
                pendingPosition: nil,
                attemptsRemaining: 2
            )
        } else if case .replaying(let expectedBoundary, _) = notificationScrollRestoreState {
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

    func armSessionScrollbackReplay(expectedStartBoundary: String, expectedEndBoundary: String) {
        notificationScrollRestoreState = .armed(
            expectedStartBoundary: expectedStartBoundary,
            expectedEndBoundary: expectedEndBoundary,
            pendingPosition: notificationScrollRestoreState.pendingPosition,
            attemptsRemaining: 2
        )
    }

    func armSessionScrollbackReplay(from environment: [String: String]) {
        guard let path = environment[SessionScrollbackReplayStore.environmentKey] else { return }
        armSessionScrollbackReplay(
            expectedStartBoundary: SessionScrollbackReplayStore.startBoundaryValue(forReplayFilePath: path),
            expectedEndBoundary: SessionScrollbackReplayStore.endBoundaryValue(forReplayFilePath: path)
        )
    }

    @discardableResult
    func sessionScrollbackReplayDidReceiveBoundary(_ boundary: String) -> Bool {
        if case .armed(let expectedStartBoundary, let expectedEndBoundary, let pendingPosition, _) =
            notificationScrollRestoreState,
            boundary == expectedStartBoundary {
            notificationScrollRestoreState = .replaying(
                expectedBoundary: expectedEndBoundary,
                pendingPosition: pendingPosition
            )
            return true
        }
        guard case .replaying(let expectedEndBoundary, let pendingPosition) = notificationScrollRestoreState,
              boundary == expectedEndBoundary else {
            return false
        }
        guard let pendingPosition else {
            notificationScrollRestoreState = .inactive
            return true
        }
        notificationScrollRestoreState = .awaitingPostReplayGeometry(
            position: pendingPosition,
            attemptsRemaining: 2,
            provisionalTopRow: nil
        )
        _ = restorePendingNotificationScrollPositionIfReady()
        return true
    }

    var hasPendingNotificationScrollRestore: Bool {
        notificationScrollRestoreState.pendingPosition != nil
    }

    func terminalSurfaceDidReceiveExplicitInput() {
        cancelPendingNotificationScrollRestoreForUserInput()
    }
}
