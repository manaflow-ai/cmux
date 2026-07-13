import Foundation

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
        guard let position else {
            cancelPendingNotificationScrollRestore()
            return false
        }
        notificationScrollRestorePhase = .pending(
            position,
            sessionScrollbackReplayCompletionMarker: notificationScrollRestorePhase.sessionScrollbackReplayCompletionMarker
        )
        if notificationScrollRestorePhase.sessionScrollbackReplayCompletionMarker != nil {
            scheduleSessionScrollbackReplayCompletionDeadline()
        }
        return retryPendingNotificationScrollRestore()
    }

    @discardableResult
    func retryPendingNotificationScrollRestore(rendererScrollbarGeneration: UInt64? = nil) -> Bool {
        guard case .pending(let position, let completionMarker) = notificationScrollRestorePhase else {
            return false
        }
        if let markerGeneration = sessionScrollbackReplayMarkerScrollbarGeneration {
            guard let rendererScrollbarGeneration,
                  rendererScrollbarGeneration > markerGeneration else { return true }
            sessionScrollbackReplayMarkerScrollbarGeneration = nil
        }
        switch notificationScrollRestoreDecision(
            position,
            waitingForSessionScrollbackReplay: completionMarker != nil
        ) {
        case .waitForViewport:
            return true
        case .perform(let target):
            notificationScrollRestorePhase = completionMarker.map(TerminalNotificationScrollRestorePhase.sessionScrollbackReplayActive) ?? .idle
            guard performNotificationScrollRestore(target) else {
                notificationScrollRestorePhase = .pending(
                    position,
                    sessionScrollbackReplayCompletionMarker: completionMarker
                )
                return true
            }
            cancelSessionScrollbackReplayCompletionDeadline()
            return true
        }
    }

    func cancelPendingNotificationScrollRestore() {
        cancelSessionScrollbackReplayCompletionDeadline()
        sessionScrollbackReplayMarkerScrollbarGeneration = nil
        notificationScrollRestorePhase = notificationScrollRestorePhase.sessionScrollbackReplayCompletionMarker
            .map(TerminalNotificationScrollRestorePhase.sessionScrollbackReplayActive) ?? .idle
    }

    func beginSessionScrollbackReplay(completionMarker: SessionScrollbackReplayCompletionMarker) {
        sessionScrollbackReplayMarkerScrollbarGeneration = nil
        switch notificationScrollRestorePhase {
        case .idle:
            notificationScrollRestorePhase = .sessionScrollbackReplayActive(completionMarker)
        case .sessionScrollbackReplayActive:
            notificationScrollRestorePhase = .sessionScrollbackReplayActive(completionMarker)
        case .pending(let position, _):
            notificationScrollRestorePhase = .pending(
                position,
                sessionScrollbackReplayCompletionMarker: completionMarker
            )
        }
        if case .pending = notificationScrollRestorePhase {
            scheduleSessionScrollbackReplayCompletionDeadline()
        }
    }

    func hasSessionScrollbackReplayCompletionMarker(matching reportedDirectory: String) -> Bool {
        notificationScrollRestorePhase.sessionScrollbackReplayCompletionMarker?.reportedDirectory == reportedDirectory
    }

    @discardableResult
    func completeSessionScrollbackReplay(
        ifMatches reportedDirectory: String
    ) -> Bool {
        guard hasSessionScrollbackReplayCompletionMarker(matching: reportedDirectory) else { return false }
        switch notificationScrollRestorePhase {
        case .idle:
            break
        case .sessionScrollbackReplayActive:
            notificationScrollRestorePhase = .idle
            cancelSessionScrollbackReplayCompletionDeadline()
        case .pending(let position, _):
            notificationScrollRestorePhase = .pending(
                position,
                sessionScrollbackReplayCompletionMarker: nil
            )
            sessionScrollbackReplayMarkerScrollbarGeneration = surfaceView.currentScrollbarEnqueueGeneration()
        }
        return true
    }

    func expireSessionScrollbackReplayCompletionDeadline() {
        guard notificationScrollRestorePhase.sessionScrollbackReplayCompletionMarker != nil ||
                sessionScrollbackReplayMarkerScrollbarGeneration != nil else { return }
        cancelSessionScrollbackReplayCompletionDeadline()
        sessionScrollbackReplayMarkerScrollbarGeneration = nil
        switch notificationScrollRestorePhase {
        case .idle:
            break
        case .sessionScrollbackReplayActive:
            notificationScrollRestorePhase = .idle
        case .pending(let position, _):
            notificationScrollRestorePhase = .pending(
                position,
                sessionScrollbackReplayCompletionMarker: nil
            )
            _ = retryPendingNotificationScrollRestore()
        }
    }

    private func scheduleSessionScrollbackReplayCompletionDeadline() {
        cancelSessionScrollbackReplayCompletionDeadline()
        // The OSC 7 marker is the synchronization signal. This deadline only
        // prevents a missing or disabled shell integration from waiting forever.
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            self?.expireSessionScrollbackReplayCompletionDeadline()
        }
        sessionScrollbackReplayCompletionDeadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSessionScrollbackReplayCompletionDeadline() {
        sessionScrollbackReplayCompletionDeadlineTimer?.invalidate()
        sessionScrollbackReplayCompletionDeadlineTimer = nil
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
        _ position: TerminalNotificationScrollPosition,
        waitingForSessionScrollbackReplay: Bool
    ) -> TerminalNotificationScrollRestoreDecision {
        if position.row <= 0 {
            return .perform(.bottom)
        }
        guard let scrollbar = surfaceView.scrollbar else { return .waitForViewport }
        let currentTotalRows = Int(clamping: scrollbar.total)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: scrollbar.len))
        guard currentVisibleRows > 0 else { return .waitForViewport }

        guard let capturedTotalRows = position.totalRows else {
            return waitingForSessionScrollbackReplay
                ? .waitForViewport
                : notificationScrollRestoreTarget(position).map(TerminalNotificationScrollRestoreDecision.perform) ?? .waitForViewport
        }
        let capturedViewportBottomRow = max(0, capturedTotalRows) - min(max(0, capturedTotalRows), max(0, position.row))

        // A newly restored terminal can report a nonzero viewport before its
        // historical rows finish replaying. Keep the anchor pending until the
        // captured viewport exists instead of permanently clamping it to the
        // partial buffer.
        if waitingForSessionScrollbackReplay, currentTotalRows < capturedViewportBottomRow {
            return .waitForViewport
        }
        guard let target = notificationScrollRestoreTarget(position) else { return .waitForViewport }
        return .perform(target)
    }

    func notificationScrollRestoreTarget(
        _ position: TerminalNotificationScrollPosition?
    ) -> TerminalNotificationScrollRestoreTarget? {
        guard let position else { return nil }
        if position.row <= 0 {
            return .bottom
        }
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        let currentTotalRows = Int(clamping: scrollbar.total)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: scrollbar.len))
        guard currentVisibleRows > 0 else { return nil }
        let currentLastTopRow = currentTotalRows - currentVisibleRows
        guard let capturedTotalRows = position.totalRows else {
            return .absoluteRow(max(0, currentLastTopRow - max(0, position.row)))
        }
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
