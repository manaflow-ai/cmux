import CmuxTerminalCore
import Foundation

@MainActor
extension GhosttySurfaceScrollView {
    private static let maxPostReplayUnaddressableGeometryUpdates = 32

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
                unaddressableGeometryUpdatesRemaining: Self.maxPostReplayUnaddressableGeometryUpdates
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
        consumeUnaddressableGeometryUpdate: Bool = false
    ) -> Bool {
        let position: TerminalNotificationScrollPosition
        let attemptsRemaining: Int
        let isPostReplayGeometry: Bool
        let unaddressableGeometryUpdatesRemaining: Int?
        let armedBoundaries: (start: String, end: String)?
        switch notificationScrollRestoreState {
        case .inactive, .replaying:
            return false
        case .armed(let expectedStartBoundary, let expectedEndBoundary, let pendingPosition, let pendingAttempts):
            guard let pendingPosition else { return false }
            position = pendingPosition
            attemptsRemaining = pendingAttempts
            isPostReplayGeometry = false
            unaddressableGeometryUpdatesRemaining = nil
            armedBoundaries = (expectedStartBoundary, expectedEndBoundary)
        case .awaitingInitialGeometry(let pendingPosition, let pendingAttempts):
            position = pendingPosition
            attemptsRemaining = pendingAttempts
            isPostReplayGeometry = false
            unaddressableGeometryUpdatesRemaining = nil
            armedBoundaries = nil
        case .awaitingPostReplayGeometry(
            let pendingPosition,
            let pendingAttempts,
            let pendingUnaddressableGeometryUpdates
        ):
            position = pendingPosition
            attemptsRemaining = pendingAttempts
            isPostReplayGeometry = true
            unaddressableGeometryUpdatesRemaining = pendingUnaddressableGeometryUpdates
            armedBoundaries = nil
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
            if !isPostReplayGeometry, armedBoundaries == nil {
                clearPendingNotificationScrollRestore()
            } else if isPostReplayGeometry,
               consumeUnaddressableGeometryUpdate,
               let unaddressableGeometryUpdatesRemaining {
                let remainingAfterUpdate = unaddressableGeometryUpdatesRemaining - 1
                if remainingAfterUpdate <= 0 {
                    clearPendingNotificationScrollRestore()
                } else {
                    notificationScrollRestoreState = .awaitingPostReplayGeometry(
                        position: position,
                        attemptsRemaining: attemptsRemaining,
                        unaddressableGeometryUpdatesRemaining: remainingAfterUpdate
                    )
                }
            }
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
            } else if let armedBoundaries {
                notificationScrollRestoreState = .armed(
                    expectedStartBoundary: armedBoundaries.start,
                    expectedEndBoundary: armedBoundaries.end,
                    pendingPosition: position,
                    attemptsRemaining: remainingAfterAttempt
                )
            } else if isPostReplayGeometry {
                notificationScrollRestoreState = .awaitingPostReplayGeometry(
                    position: position,
                    attemptsRemaining: remainingAfterAttempt,
                    unaddressableGeometryUpdatesRemaining: unaddressableGeometryUpdatesRemaining
                        ?? Self.maxPostReplayUnaddressableGeometryUpdates
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
            unaddressableGeometryUpdatesRemaining: Self.maxPostReplayUnaddressableGeometryUpdates
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
