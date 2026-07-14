import CmuxTerminalCore
import Foundation

@MainActor
extension GhosttySurfaceScrollView {
    var notificationScrollPosition: TerminalNotificationScrollPosition? {
        guard let geometry = surfaceView.authoritativeScrollbarGeometry() else { return nil }
        guard let anchor = TerminalScrollbackViewportAnchor(scrollbar: geometry.scrollbar) else { return nil }
        return TerminalNotificationScrollPosition(
            row: anchor.rowsBelowViewport,
            totalRows: anchor.capturedTotalRows,
            rowSpaceRevision: geometry.rowSpaceRevision
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
            return false
        case .replaying(let expectedBoundary, _):
            notificationScrollRestoreState = .replaying(
                expectedBoundary: expectedBoundary,
                pendingPosition: position
            )
            return false
        case .awaitingPostReplayGeometry(_, _, let replayCompletionGeometry):
            notificationScrollRestoreState = .awaitingPostReplayGeometry(
                position: position,
                attemptsRemaining: 2,
                replayCompletionGeometry: replayCompletionGeometry
            )
        case .replayCompleted(let geometry):
            notificationScrollRestoreState = .awaitingPostReplayGeometry(
                position: position,
                attemptsRemaining: 2,
                replayCompletionGeometry: geometry
            )
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
        authoritativeGeometry: NotificationScrollRestoreGeometry? = nil
    ) -> Bool {
        switch notificationScrollRestoreState {
        case .inactive, .armed, .replaying, .replayCompleted:
            return false
        case .awaitingInitialGeometry(let position, let attemptsRemaining):
            return restoreInitialNotificationScrollPosition(
                position,
                attemptsRemaining: attemptsRemaining
            )
        case .awaitingPostReplayGeometry(
            let pendingPosition,
            let attemptsRemaining,
            let replayCompletionGeometry
        ):
            guard let pendingPosition else {
                guard let geometry = authoritativeGeometry ?? surfaceView.authoritativeScrollbarGeometry() else {
                    return false
                }
                notificationScrollRestoreState = .replayCompleted(geometry: geometry)
                return false
            }
            return restorePostReplayNotificationScrollPosition(
                pendingPosition,
                attemptsRemaining: attemptsRemaining,
                authoritativeGeometry: authoritativeGeometry,
                replayCompletionGeometry: replayCompletionGeometry
            )
        }
    }

    private func restoreInitialNotificationScrollPosition(
        _ position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int
    ) -> Bool {
        guard attemptsRemaining > 0 else {
            clearPendingNotificationScrollRestore()
            return false
        }
        guard let geometry = surfaceView.authoritativeScrollbarGeometry() else { return false }
        if let capturedRevision = position.rowSpaceRevision,
           position.row != 0,
           capturedRevision != geometry.rowSpaceRevision {
            clearPendingNotificationScrollRestore()
            return false
        }
        guard let targetTopRow = targetTopRow(
            for: position,
            in: geometry.scrollbar,
            rebaseToCurrentRows: false
        ) else {
            clearPendingNotificationScrollRestore()
            return false
        }

        return applyNotificationScrollRestore(
            targetTopRow: targetTopRow,
            scrollbar: geometry.scrollbar,
            attemptsRemaining: attemptsRemaining,
            perform: {
                self.surfaceView.scrollToRow(
                    targetTopRow,
                    ifRowSpaceRevisionMatches: position.row == 0
                        ? geometry.rowSpaceRevision
                        : position.rowSpaceRevision ?? geometry.rowSpaceRevision
                ) != nil
            },
            pendingState: { remaining in
                .awaitingInitialGeometry(position: position, attemptsRemaining: remaining)
            }
        )
    }

    private func restorePostReplayNotificationScrollPosition(
        _ position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        replayCompletionGeometry: NotificationScrollRestoreGeometry?
    ) -> Bool {
        guard attemptsRemaining > 0 else {
            clearPendingNotificationScrollRestore()
            return false
        }
        guard let geometry = authoritativeGeometry ?? surfaceView.authoritativeScrollbarGeometry() else {
            return false
        }
        let anchorGeometry = replayCompletionGeometry ?? geometry
        if position.row != 0,
           anchorGeometry.rowSpaceRevision != geometry.rowSpaceRevision {
            clearPendingNotificationScrollRestore()
            return false
        }
        let anchorScrollbar = position.row == 0 ? geometry.scrollbar : anchorGeometry.scrollbar
        let shouldRebase = position.totalRows.map {
            Int(clamping: anchorScrollbar.total) < $0
        } == true
        guard let targetTopRow = targetTopRow(
            for: position,
            in: anchorScrollbar,
            rebaseToCurrentRows: shouldRebase
        ) else {
            return false
        }

        return applyNotificationScrollRestore(
            targetTopRow: targetTopRow,
            scrollbar: geometry.scrollbar,
            attemptsRemaining: attemptsRemaining,
            perform: {
                self.surfaceView.scrollToRow(
                    targetTopRow,
                    ifRowSpaceRevisionMatches: geometry.rowSpaceRevision
                ) != nil
            },
            pendingState: { remaining in
                .awaitingPostReplayGeometry(
                    position: position,
                    attemptsRemaining: remaining,
                    replayCompletionGeometry: anchorGeometry
                )
            }
        )
    }

    private func targetTopRow(
        for position: TerminalNotificationScrollPosition,
        in scrollbar: GhosttyScrollbar,
        rebaseToCurrentRows: Bool
    ) -> Int? {
        let currentTotalRows = Int(clamping: scrollbar.total)
        let capturedTotalRows = rebaseToCurrentRows
            ? currentTotalRows
            : position.totalRows ?? currentTotalRows
        return TerminalScrollbackViewportAnchor(
            rowsBelowViewport: position.row,
            capturedTotalRows: capturedTotalRows
        ).topRow(in: scrollbar)
    }

    private func applyNotificationScrollRestore(
        targetTopRow: Int,
        scrollbar: GhosttyScrollbar,
        attemptsRemaining: Int,
        perform: () -> Bool,
        pendingState: (Int) -> NotificationScrollRestoreState
    ) -> Bool {
        let currentLastTopRow = Int(clamping: scrollbar.total - min(scrollbar.total, scrollbar.len))
        let previousUserScrolledAwayFromBottom = userScrolledAwayFromBottom
        allowExplicitScrollbarSync = true
        userScrolledAwayFromBottom = targetTopRow < currentLastTopRow
        let didRestore = perform()
        if didRestore {
            clearPendingNotificationScrollRestore()
        } else {
            allowExplicitScrollbarSync = false
            userScrolledAwayFromBottom = previousUserScrolledAwayFromBottom
            let remainingAfterAttempt = attemptsRemaining - 1
            if remainingAfterAttempt == 0 {
                clearPendingNotificationScrollRestore()
            } else {
                notificationScrollRestoreState = pendingState(remainingAfterAttempt)
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
        if case .awaitingPostReplayGeometry(
            let pendingPosition,
            _,
            let replayCompletionGeometry
        ) = notificationScrollRestoreState {
            guard pendingPosition != nil else { return }
            if let replayCompletionGeometry {
                notificationScrollRestoreState = .replayCompleted(geometry: replayCompletionGeometry)
            } else {
                notificationScrollRestoreState = .awaitingPostReplayGeometry(
                    position: nil,
                    attemptsRemaining: 2,
                    replayCompletionGeometry: nil
                )
            }
            return
        }
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
    func sessionScrollbackReplayDidReceiveBoundary(
        _ boundary: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry? = nil
    ) -> Bool {
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
        let replayCompletionGeometry = authoritativeGeometry ?? surfaceView.authoritativeScrollbarGeometry()
        guard let pendingPosition else {
            if let replayCompletionGeometry {
                notificationScrollRestoreState = .replayCompleted(geometry: replayCompletionGeometry)
            } else {
                notificationScrollRestoreState = .awaitingPostReplayGeometry(
                    position: nil,
                    attemptsRemaining: 2,
                    replayCompletionGeometry: nil
                )
            }
            return true
        }
        notificationScrollRestoreState = .awaitingPostReplayGeometry(
            position: pendingPosition,
            attemptsRemaining: 2,
            replayCompletionGeometry: replayCompletionGeometry
        )
        _ = restorePendingNotificationScrollPositionIfReady(
            authoritativeGeometry: authoritativeGeometry
        )
        return true
    }

    var hasPendingNotificationScrollRestore: Bool {
        notificationScrollRestoreState.pendingPosition != nil
    }

    func terminalSurfaceDidReceiveExplicitInput() {
        cancelPendingNotificationScrollRestoreForUserInput()
    }

    func restorePendingNotificationScrollPositionAfterScrollbarUpdate() {
        _ = restorePendingNotificationScrollPositionIfReady()
    }
}

@MainActor
extension GhosttyNSView {
    func authoritativeScrollbarGeometry() -> NotificationScrollRestoreGeometry? {
        var result = ghostty_surface_scrollbar_s()
        guard readAuthoritativeScrollbar(&result) else { return nil }
        return NotificationScrollRestoreGeometry(c: result)
    }

    func scrollToRow(
        _ row: Int,
        ifRowSpaceRevisionMatches rowSpaceRevision: UInt64
    ) -> NotificationScrollRestoreGeometry? {
        guard let row = UInt64(exactly: row) else { return nil }
        var result = ghostty_surface_scrollbar_s()
        guard scrollToRow(
            row,
            ifRowSpaceRevisionMatches: rowSpaceRevision,
            result: &result
        ) else { return nil }
        return NotificationScrollRestoreGeometry(c: result)
    }
}
