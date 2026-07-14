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

        switch notificationScrollRestoreState.replay {
        case .armed, .replaying:
            notificationScrollRestoreState.request = .waitingForReplay(
                position: position,
                attemptsRemaining: 2
            )
            return false
        case .completedAwaitingGeometry where position.rowSpaceRevision == nil:
            notificationScrollRestoreState.request = .waitingForReplay(
                position: position,
                attemptsRemaining: 2
            )
            return false
        case .completed(let geometry) where position.rowSpaceRevision == nil:
            notificationScrollRestoreState.request = .awaitingPostReplayRestore(
                position: position,
                attemptsRemaining: 2,
                replayContext: .stable(geometry)
            )
        case .inactive, .completedAwaitingGeometry, .completed:
            notificationScrollRestoreState.request = .awaitingInitialGeometry(
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
        if case .completedAwaitingGeometry = notificationScrollRestoreState.replay,
           let geometry = authoritativeGeometry ?? surfaceView.authoritativeScrollbarGeometry() {
            notificationScrollRestoreState.replay = .completed(geometry)
            configureWaitingRequestAfterReplay(using: geometry)
        }

        switch notificationScrollRestoreState.request {
        case .idle, .waitingForReplay:
            return false
        case .awaitingInitialGeometry(let position, let attemptsRemaining):
            return restoreInitialNotificationScrollPosition(
                position,
                attemptsRemaining: attemptsRemaining
            )
        case .awaitingPostReplayRestore(
            let position,
            let attemptsRemaining,
            let replayContext
        ):
            return restorePostReplayNotificationScrollPosition(
                position,
                attemptsRemaining: attemptsRemaining,
                authoritativeGeometry: authoritativeGeometry,
                replayContext: replayContext
            )
        }
    }

    private func configureWaitingRequestAfterReplay(
        using geometry: NotificationScrollRestoreGeometry
    ) {
        guard case .waitingForReplay(let position, let attemptsRemaining) =
            notificationScrollRestoreState.request else { return }
        if position.rowSpaceRevision == nil {
            notificationScrollRestoreState.request = .awaitingPostReplayRestore(
                position: position,
                attemptsRemaining: attemptsRemaining,
                replayContext: .provisional(geometry)
            )
        } else {
            notificationScrollRestoreState.request = .awaitingInitialGeometry(
                position: position,
                attemptsRemaining: attemptsRemaining
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
            pendingRequest: { remaining in
                .awaitingInitialGeometry(position: position, attemptsRemaining: remaining)
            }
        )
    }

    private func restorePostReplayNotificationScrollPosition(
        _ position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        replayContext: NotificationReplayRestoreContext
    ) -> Bool {
        guard attemptsRemaining > 0 else {
            clearPendingNotificationScrollRestore()
            return false
        }
        let currentGeometry = surfaceView.authoritativeScrollbarGeometry()
        guard let geometry = position.row == 0
            ? currentGeometry
            : authoritativeGeometry ?? currentGeometry else {
            return false
        }
        let anchorGeometry = replayContext.geometry
        if position.row != 0,
           anchorGeometry.rowSpaceRevision != geometry.rowSpaceRevision {
            clearPendingNotificationScrollRestore()
            return false
        }
        let anchorScrollbar = position.row == 0
            ? geometry.scrollbar
            : GhosttyScrollbar(
                total: anchorGeometry.scrollbar.total,
                offset: anchorGeometry.scrollbar.offset,
                len: geometry.scrollbar.len
            )
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
                    ifRowSpaceRevisionMatches: position.row == 0
                        ? geometry.rowSpaceRevision
                        : anchorGeometry.rowSpaceRevision
                ) != nil
            },
            pendingRequest: { remaining in
                return .awaitingPostReplayRestore(
                    position: position,
                    attemptsRemaining: remaining,
                    replayContext: replayContext
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
        pendingRequest: (Int) -> NotificationScrollRequestPhase
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
                notificationScrollRestoreState.request = pendingRequest(remainingAfterAttempt)
            }
        }
        return didRestore
    }

    func clearPendingNotificationScrollRestore() {
        notificationScrollRestoreState.request = .idle
    }

    func cancelPendingNotificationScrollRestoreForUserInput() {
        switch notificationScrollRestoreState.replay {
        case .armed, .replaying:
            surfaceView.cancelNotificationScrollReplayBoundaryRegistration()
            notificationScrollRestoreState.replay = .inactive
            clearPendingNotificationScrollRestore()
        case .inactive, .completedAwaitingGeometry, .completed:
            guard notificationScrollRestoreState.pendingPosition != nil else { return }
            clearPendingNotificationScrollRestore()
        }
    }

    func armSessionScrollbackReplay(expectedStartBoundary: String, expectedEndBoundary: String) {
        surfaceView.registerNotificationScrollReplayBoundaries(
            startBoundary: expectedStartBoundary,
            endBoundary: expectedEndBoundary
        )
        notificationScrollRestoreState.replay = .armed(
            expectedStartBoundary: expectedStartBoundary,
            expectedEndBoundary: expectedEndBoundary
        )
        if let position = notificationScrollRestoreState.pendingPosition {
            notificationScrollRestoreState.request = .waitingForReplay(
                position: position,
                attemptsRemaining: 2
            )
        }
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
        if case .armed(let expectedStartBoundary, let expectedEndBoundary) =
            notificationScrollRestoreState.replay,
            boundary == expectedStartBoundary {
            notificationScrollRestoreState.replay = .replaying(
                expectedEndBoundary: expectedEndBoundary
            )
            return true
        }
        guard case .replaying(let expectedEndBoundary) = notificationScrollRestoreState.replay,
              boundary == expectedEndBoundary else {
            return false
        }

        if let geometry = authoritativeGeometry ?? surfaceView.authoritativeScrollbarGeometry() {
            notificationScrollRestoreState.replay = .completed(geometry)
            configureWaitingRequestAfterReplay(using: geometry)
        } else {
            notificationScrollRestoreState.replay = .completedAwaitingGeometry
        }
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
