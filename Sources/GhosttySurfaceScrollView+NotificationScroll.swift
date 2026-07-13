import CmuxTerminal
import CmuxTerminalCore
import Foundation
import GhosttyKit

@MainActor
extension GhosttyNSView {
    func authoritativeScrollbarSnapshot() -> GhosttyScrollbar? {
        guard let terminalSurface,
              let surface = terminalSurface.liveSurfaceForGhosttyAccess(
                reason: "notificationScrollRestore.authoritativeSnapshot"
              ) else { return nil }
        var snapshot = ghostty_action_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &snapshot) else { return nil }
        return GhosttyScrollbar(c: snapshot)
    }
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
    func retryPendingNotificationScrollRestore() -> Bool {
        guard case .pending(let position, let completionMarker) = notificationScrollRestorePhase else {
            return false
        }
        guard completionMarker == nil else { return true }
        switch notificationScrollRestoreDecision(position) {
        case .waitForViewport:
            return true
        case .perform(let target):
            notificationScrollRestorePhase = .idle
            guard performNotificationScrollRestore(target) else {
                notificationScrollRestorePhase = .pending(
                    position,
                    sessionScrollbackReplayCompletionMarker: nil
                )
                return true
            }
            cancelSessionScrollbackReplayCompletionDeadline()
            return true
        }
    }

    func cancelPendingNotificationScrollRestore() {
        guard case .pending(_, let completionMarker) = notificationScrollRestorePhase else { return }
        cancelSessionScrollbackReplayCompletionDeadline()
        notificationScrollRestorePhase = completionMarker
            .map(TerminalNotificationScrollRestorePhase.sessionScrollbackReplayActive) ?? .idle
    }

    func beginSessionScrollbackReplay(completionMarker: SessionScrollbackReplayCompletionMarker) {
        let completedBeforeActivation = earlySessionScrollbackReplayCompletionDirectory == completionMarker.reportedDirectory
        earlySessionScrollbackReplayCompletionDirectory = nil
        if completedBeforeActivation {
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
            return
        }
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
        guard hasSessionScrollbackReplayCompletionMarker(matching: reportedDirectory) else {
            guard SessionScrollbackReplayCompletionMarker.isReservedReportedDirectory(reportedDirectory) else { return false }
            switch notificationScrollRestorePhase {
            case .idle, .pending(_, sessionScrollbackReplayCompletionMarker: nil):
                earlySessionScrollbackReplayCompletionDirectory = reportedDirectory
            case .sessionScrollbackReplayActive,
                 .pending(_, sessionScrollbackReplayCompletionMarker: .some(_)):
                return false
            }
        }

        cancelSessionScrollbackReplayCompletionDeadline()
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
        }

        guard refreshAuthoritativeScrollbar() else {
            cancelPendingNotificationScrollRestore()
            return true
        }
        _ = retryPendingNotificationScrollRestore()
        return true
    }

    func expireSessionScrollbackReplayCompletionDeadline() {
        guard case .pending(_, sessionScrollbackReplayCompletionMarker: .some(_)) = notificationScrollRestorePhase else {
            return
        }
        cancelSessionScrollbackReplayCompletionDeadline()
        notificationScrollRestorePhase = .idle
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

    private func refreshAuthoritativeScrollbar() -> Bool {
        guard let snapshot = surfaceView.authoritativeScrollbarSnapshot() else { return false }
        surfaceView.enqueueScrollbarUpdate(snapshot)
        return surfaceView.flushPendingScrollbarIfAvailable()
    }

    private func performNotificationScrollRestore(_ target: TerminalNotificationScrollRestoreTarget) -> Bool {
        allowExplicitScrollbarSync = true
        let didRestore: Bool
        switch target {
        case .bottom:
            didRestore = surfaceView.performBindingAction("scroll_to_bottom", recordsExplicitInput: false)
            if didRestore {
                userScrolledAwayFromBottom = false
            }
        case .absoluteRow(let targetTopRow):
            let currentTotalRows = Int(clamping: surfaceView.scrollbar?.total ?? 0)
            let currentVisibleRows = min(currentTotalRows, Int(clamping: surfaceView.scrollbar?.len ?? 0))
            let currentLastTopRow = currentTotalRows - currentVisibleRows
            didRestore = surfaceView.performBindingAction("scroll_to_row:\(targetTopRow)", recordsExplicitInput: false)
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
        if position.row <= 0 {
            return .perform(.bottom)
        }
        guard let scrollbar = surfaceView.scrollbar else { return .waitForViewport }
        let currentTotalRows = Int(clamping: scrollbar.total)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: scrollbar.len))
        guard currentVisibleRows > 0 else { return .waitForViewport }

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
        let discardedPrefixRows = max(0, normalizedCapturedTotalRows - currentTotalRows)
        let retainedViewportBottomRow = max(0, capturedViewportBottomRow - discardedPrefixRows)

        // Session persistence retains a suffix of scrollback. Translate the
        // captured viewport into that suffix before using Ghostty's absolute row.
        let unclampedTopRow = max(0, retainedViewportBottomRow - currentVisibleRows)
        return .absoluteRow(min(currentLastTopRow, unclampedTopRow))
    }
}
