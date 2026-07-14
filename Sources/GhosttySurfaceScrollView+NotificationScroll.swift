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
            return false
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
        case .inactive, .armed, .replaying:
            return false
        case .awaitingInitialGeometry(let position, let attemptsRemaining):
            return restoreInitialNotificationScrollPosition(
                position,
                attemptsRemaining: attemptsRemaining
            )
        case .awaitingPostReplayGeometry(let pendingPosition, let attemptsRemaining):
            guard let pendingPosition else { return false }
            return restorePostReplayNotificationScrollPosition(
                pendingPosition,
                attemptsRemaining: attemptsRemaining,
                authoritativeGeometry: authoritativeGeometry
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
        guard let scrollbar = surfaceView.scrollbar else { return false }
        guard let targetTopRow = targetTopRow(for: position, in: scrollbar, rebaseToCurrentRows: false) else {
            clearPendingNotificationScrollRestore()
            return false
        }

        return applyNotificationScrollRestore(
            targetTopRow: targetTopRow,
            scrollbar: scrollbar,
            attemptsRemaining: attemptsRemaining,
            perform: {
                let lastTopRow = Int(clamping: scrollbar.total - min(scrollbar.total, scrollbar.len))
                let action = targetTopRow == lastTopRow
                    ? "scroll_to_bottom"
                    : "scroll_to_row:\(targetTopRow)"
                return self.surfaceView.performBindingAction(action)
            },
            pendingState: { remaining in
                .awaitingInitialGeometry(position: position, attemptsRemaining: remaining)
            }
        )
    }

    private func restorePostReplayNotificationScrollPosition(
        _ position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int,
        authoritativeGeometry: NotificationScrollRestoreGeometry?
    ) -> Bool {
        guard attemptsRemaining > 0 else {
            clearPendingNotificationScrollRestore()
            return false
        }
        guard let geometry = authoritativeGeometry ?? surfaceView.authoritativeScrollbarGeometry() else {
            return false
        }
        let shouldRebase = attemptsRemaining < 2 || position.totalRows.map {
            Int(clamping: geometry.scrollbar.total) < $0
        } == true
        guard let targetTopRow = targetTopRow(
            for: position,
            in: geometry.scrollbar,
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
                .awaitingPostReplayGeometry(position: position, attemptsRemaining: remaining)
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
        notificationScrollRestoreState = .awaitingPostReplayGeometry(
            position: pendingPosition,
            attemptsRemaining: 2
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
