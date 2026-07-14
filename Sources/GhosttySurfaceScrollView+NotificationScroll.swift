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
            if let scrollbar = surfaceView.scrollbar,
               min(scrollbar.total, scrollbar.len) > 0 {
                scheduleNotificationScrollRestoreFrameDeadline()
            }
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
        isPostReplayGeometryUpdate: Bool = false,
        isAuthoritativePostReplayFrame: Bool = false
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
            guard let pendingPosition else { return false }
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
        if isPostReplayGeometry,
           isPostReplayGeometryUpdate,
           !isAuthoritativePostReplayFrame,
           notificationScrollRestoreRenderedFrameObserver != nil {
            return false
        }
        // Legacy anchors have no captured total, so stale boundary-time geometry
        // cannot distinguish the saved viewport from a partial replay snapshot.
        if isPostReplayGeometry,
           position.totalRows == nil,
           !isPostReplayGeometryUpdate {
            return false
        }
        let capturedTotalRows = position.totalRows ?? Int(clamping: scrollbar.total)
        if isPostReplayGeometry,
           !isAuthoritativePostReplayFrame,
           Int(clamping: scrollbar.total) < capturedTotalRows {
            return false
        }
        let anchor = TerminalScrollbackViewportAnchor(
            rowsBelowViewport: position.row,
            capturedTotalRows: capturedTotalRows
        )
        let targetTopRow: Int?
        if isPostReplayGeometry,
           isAuthoritativePostReplayFrame,
           let originalTotalRows = position.totalRows,
           Int(clamping: scrollbar.total) < originalTotalRows {
            // Session persistence retains a bounded suffix. Once replay has
            // completed, translate an evicted absolute row into that suffix.
            targetTopRow = TerminalScrollbackViewportAnchor(
                rowsBelowViewport: position.row,
                capturedTotalRows: Int(clamping: scrollbar.total)
            ).topRow(in: scrollbar)
        } else if let exactTopRow = anchor.topRow(in: scrollbar) {
            targetTopRow = exactTopRow
        } else if isPostReplayGeometry,
                  isAuthoritativePostReplayFrame,
                  position.totalRows != nil {
            targetTopRow = TerminalScrollbackViewportAnchor(
                rowsBelowViewport: position.row,
                capturedTotalRows: Int(clamping: scrollbar.total)
            ).topRow(in: scrollbar)
        } else {
            targetTopRow = nil
        }
        guard let targetTopRow else {
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
        cancelNotificationScrollRestoreFrameWait()
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
        cancelNotificationScrollRestoreFrameWait()
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
            scheduleNotificationScrollRestoreFrameDeadline()
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
            attemptsRemaining: 2,
            provisionalTopRow: nil
        )
        beginNotificationScrollRestoreFrameWait()
        _ = restorePendingNotificationScrollPositionIfReady()
        return true
    }

    private func beginNotificationScrollRestoreFrameWait() {
        cancelNotificationScrollRestoreFrameWait()
        scheduleNotificationScrollRestoreFrameDeadline()
        releaseNotificationScrollRestoreFrameDemand = surfaceView.retainTargetedRenderedFrameNotifications()
        notificationScrollRestoreHasPostBoundaryScrollbar = false
        notificationScrollRestoreBoundaryFrameGeneration = surfaceView.currentRenderedFrameSourceGeneration()
        notificationScrollRestoreRenderedFrameObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let boundaryGeneration = self.notificationScrollRestoreBoundaryFrameGeneration,
                      let renderedGeneration = notification.userInfo?[GhosttyNotificationKey.renderedFrameGeneration]
                        as? UInt64,
                      renderedGeneration > boundaryGeneration else {
                    return
                }
                // Drawable acquisition precedes Ghostty's matching scrollbar
                // publication. Mark the frame observed, then let that subsequent
                // scrollbar update provide the authoritative geometry.
                self.notificationScrollRestoreBoundaryFrameGeneration = nil
                if self.notificationScrollRestoreHasPostBoundaryScrollbar {
                    _ = self.restorePendingNotificationScrollPositionIfReady(
                        isPostReplayGeometryUpdate: true,
                        isAuthoritativePostReplayFrame: true
                    )
                }
            }
        }
        surfaceView.terminalSurface?.forceRefresh(reason: "notificationScrollRestoreReplayBoundary")
    }

    private func scheduleNotificationScrollRestoreFrameDeadline() {
        notificationScrollRestoreFrameDeadlineTimer?.invalidate()
        // The rendered frame is the authority signal. This deadline only prevents
        // a hidden or torn-down renderer from retaining this surface's frame demand.
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.expireNotificationScrollRestoreFrameDeadline()
            }
        }
        notificationScrollRestoreFrameDeadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func expireNotificationScrollRestoreFrameDeadline() {
        guard notificationScrollRestoreFrameDeadlineTimer != nil else { return }
        let preReplayFallback: (TerminalNotificationScrollPosition?, Int)?
        switch notificationScrollRestoreState {
        case .armed(_, _, let pendingPosition, let attemptsRemaining):
            preReplayFallback = (pendingPosition, attemptsRemaining)
        case .replaying(_, let pendingPosition):
            preReplayFallback = (pendingPosition, 2)
        default:
            preReplayFallback = nil
        }
        if let (pendingPosition, attemptsRemaining) = preReplayFallback {
            cancelNotificationScrollRestoreFrameWait()
            if let pendingPosition {
                notificationScrollRestoreState = .awaitingInitialGeometry(
                    position: pendingPosition,
                    attemptsRemaining: attemptsRemaining
                )
                _ = restorePendingNotificationScrollPositionIfReady()
            } else {
                notificationScrollRestoreState = .inactive
            }
            return
        }
        cancelNotificationScrollRestoreFrameWait()
        notificationScrollRestoreState = .inactive
    }

    func cancelNotificationScrollRestoreFrameWait() {
        cancelNotificationScrollRestoreDeadlineTimer()
        if let observer = notificationScrollRestoreRenderedFrameObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationScrollRestoreRenderedFrameObserver = nil
        }
        releaseNotificationScrollRestoreFrameDemand?()
        releaseNotificationScrollRestoreFrameDemand = nil
        notificationScrollRestoreHasPostBoundaryScrollbar = false
        notificationScrollRestoreBoundaryFrameGeneration = nil
    }

    private func cancelNotificationScrollRestoreDeadlineTimer() {
        notificationScrollRestoreFrameDeadlineTimer?.invalidate()
        notificationScrollRestoreFrameDeadlineTimer = nil
    }

    var hasPendingNotificationScrollRestore: Bool {
        notificationScrollRestoreState.pendingPosition != nil
    }

    func terminalSurfaceDidReceiveExplicitInput() {
        cancelPendingNotificationScrollRestoreForUserInput()
    }

    func restorePendingNotificationScrollPositionAfterScrollbarUpdate() {
        if case .armed(_, _, let pendingPosition, _) = notificationScrollRestoreState,
           pendingPosition != nil,
           notificationScrollRestoreFrameDeadlineTimer == nil {
            scheduleNotificationScrollRestoreFrameDeadline()
        }
        let isAwaitingPostReplayGeometry: Bool
        if case .awaitingPostReplayGeometry = notificationScrollRestoreState {
            isAwaitingPostReplayGeometry = true
        } else {
            isAwaitingPostReplayGeometry = false
        }
        if isAwaitingPostReplayGeometry,
           notificationScrollRestoreRenderedFrameObserver != nil,
           notificationScrollRestoreBoundaryFrameGeneration != nil {
            notificationScrollRestoreHasPostBoundaryScrollbar = true
        }
        let isAuthoritativePostReplayFrame = isAwaitingPostReplayGeometry &&
            notificationScrollRestoreBoundaryFrameGeneration == nil
        if isAuthoritativePostReplayFrame, notificationScrollRestoreState.pendingPosition == nil {
            clearPendingNotificationScrollRestore()
            return
        }
        _ = restorePendingNotificationScrollPositionIfReady(
            isPostReplayGeometryUpdate: true,
            isAuthoritativePostReplayFrame: isAuthoritativePostReplayFrame
        )
    }
}
