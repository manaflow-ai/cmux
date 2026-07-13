import CmuxTerminal
import CmuxTerminalCore
import Foundation
import GhosttyKit

@MainActor
extension GhosttySurfaceScrollView {
    var notificationScrollPosition: TerminalNotificationScrollPosition? {
        guard let snapshot = authoritativeNotificationScrollbarSnapshot() ?? surfaceView.scrollbar.map({
            (scrollbar: $0, rowSpaceRevision: currentScrollbackRowSpaceRevision ?? 0)
        }) else { return nil }
        let scrollbar = snapshot.scrollbar
        let rowFromBottom = max(0, scrollbar.total - scrollbar.offset - scrollbar.len)
        return TerminalNotificationScrollPosition(
            row: Int(clamping: rowFromBottom),
            totalRows: Int(clamping: scrollbar.total),
            replayGeneration: sessionScrollbackReplayGeneration,
            rowSpaceRevision: snapshot.rowSpaceRevision
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
        let authoritativeSnapshot = authoritativeNotificationScrollbarSnapshot()
        if let authoritativeSnapshot {
            updateScrollbackRowSpaceRevision(authoritativeSnapshot.rowSpaceRevision)
        }
        if notificationScrollRestoreHasInvalidatedReplayGeometry(position) {
            notificationScrollRestorePhase = .idle
            return false
        }
        switch notificationScrollRestoreDecision(
            position,
            scrollbar: scrollbarForNotificationScrollRestore(
                position,
                liveScrollbar: authoritativeSnapshot?.scrollbar ?? surfaceView.scrollbar
            )
        ) {
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
        if let completionMarker {
            notificationScrollRestorePhase = .sessionScrollbackReplayActive(completionMarker)
            cancelSessionScrollbackReplayCompletionDeadline()
        } else {
            cancelSessionScrollbackReplayCompletionDeadline()
            notificationScrollRestorePhase = .idle
        }
    }

    func beginSessionScrollbackReplay(completionMarker: SessionScrollbackReplayCompletionMarker) {
        cancelSessionScrollbackReplayCompletionDeadline()
        let completedBeforeActivation = earlySessionScrollbackReplayCompletionDirectory == completionMarker.reportedDirectory
        earlySessionScrollbackReplayCompletionDirectory = nil
        if sessionScrollbackReplayGeneration != completionMarker.reportedDirectory {
            sessionScrollbackReplayCompletionScrollbar = nil
            sessionScrollbackReplayCompletionRowSpaceRevision = nil
        }
        sessionScrollbackReplayGeneration = completionMarker.reportedDirectory
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
        sessionScrollbackReplayCompletionScrollbar = nil
        sessionScrollbackReplayCompletionRowSpaceRevision = nil
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
    }

    func hasSessionScrollbackReplayCompletionMarker(matching reportedDirectory: String) -> Bool {
        notificationScrollRestorePhase.sessionScrollbackReplayCompletionMarker?.reportedDirectory == reportedDirectory
    }

    @discardableResult
    func completeSessionScrollbackReplay(
        ifMatches reportedDirectory: String,
        scrollbarAtMarker: GhosttyScrollbar?,
        scrollbarRevisionAtMarker: UInt64 = 0
    ) -> Bool {
        if !hasSessionScrollbackReplayCompletionMarker(matching: reportedDirectory) {
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
        sessionScrollbackReplayGeneration = reportedDirectory
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

        guard let scrollbarAtMarker else {
            sessionScrollbackReplayCompletionScrollbar = nil
            sessionScrollbackReplayCompletionRowSpaceRevision = nil
            cancelPendingNotificationScrollRestore()
            return true
        }
        sessionScrollbackReplayCompletionScrollbar = scrollbarAtMarker
        sessionScrollbackReplayCompletionRowSpaceRevision = scrollbarRevisionAtMarker
        updateScrollbackRowSpaceRevision(scrollbarRevisionAtMarker)
        guard refreshAuthoritativeScrollbar(scrollbarAtMarker) else {
            sessionScrollbackReplayCompletionScrollbar = nil
            sessionScrollbackReplayCompletionRowSpaceRevision = nil
            cancelPendingNotificationScrollRestore()
            return true
        }
        _ = retryPendingNotificationScrollRestore()
        return true
    }

    func expireSessionScrollbackReplayCompletionDeadline() {
        switch notificationScrollRestorePhase {
        case .pending(_, sessionScrollbackReplayCompletionMarker: .some(_)):
            break
        case .idle,
             .sessionScrollbackReplayActive,
             .pending(_, sessionScrollbackReplayCompletionMarker: nil):
            return
        }
        cancelSessionScrollbackReplayCompletionDeadline()
        notificationScrollRestorePhase = .idle
    }

    private func scheduleSessionScrollbackReplayCompletionDeadline() {
        cancelSessionScrollbackReplayCompletionDeadline()
        // Artifact adoption can precede paced runtime startup. Start this bound
        // only when navigation is actually waiting for the OSC 7 marker.
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            // This timer is registered only on RunLoop.main below.
            MainActor.assumeIsolated {
                self?.expireSessionScrollbackReplayCompletionDeadline()
            }
        }
        sessionScrollbackReplayCompletionDeadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSessionScrollbackReplayCompletionDeadline() {
        sessionScrollbackReplayCompletionDeadlineTimer?.invalidate()
        sessionScrollbackReplayCompletionDeadlineTimer = nil
    }

    private func refreshAuthoritativeScrollbar(_ snapshot: GhosttyScrollbar?) -> Bool {
        guard let snapshot else { return false }
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
        _ position: TerminalNotificationScrollPosition,
        scrollbar: GhosttyScrollbar?
    ) -> TerminalNotificationScrollRestoreDecision {
        if position.row <= 0 {
            return .perform(.bottom)
        }
        guard let scrollbar else { return .waitForViewport }
        let currentTotalRows = Int(clamping: scrollbar.total)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: scrollbar.len))
        guard currentVisibleRows > 0 else { return .waitForViewport }

        guard let target = notificationScrollRestoreTarget(position, scrollbar: scrollbar) else {
            return .waitForViewport
        }
        return .perform(target)
    }

    private func scrollbarForNotificationScrollRestore(
        _ position: TerminalNotificationScrollPosition,
        liveScrollbar: GhosttyScrollbar?
    ) -> GhosttyScrollbar? {
        if let replayGeneration = sessionScrollbackReplayGeneration,
           position.replayGeneration != replayGeneration,
           let replayScrollbar = sessionScrollbackReplayCompletionScrollbar,
           let liveScrollbar {
            return GhosttyScrollbar(c: ghostty_action_scrollbar_s(
                total: replayScrollbar.total,
                offset: liveScrollbar.offset,
                len: liveScrollbar.len
            ))
        }
        return liveScrollbar
    }

    private func authoritativeNotificationScrollbarSnapshot() -> (
        scrollbar: GhosttyScrollbar,
        rowSpaceRevision: UInt64
    )? {
        guard let surface = surfaceView.terminalSurface?.surface else { return nil }
        var snapshot = ghostty_surface_scrollbar_s(
            total: 0,
            offset: 0,
            len: 0,
            row_space_revision: 0
        )
        guard ghostty_surface_scrollbar(surface, &snapshot) else { return nil }
        return (
            scrollbar: GhosttyScrollbar(c: ghostty_action_scrollbar_s(
                total: snapshot.total,
                offset: snapshot.offset,
                len: snapshot.len
            )),
            rowSpaceRevision: snapshot.row_space_revision
        )
    }

    func updateScrollbackRowSpaceRevision(_ revision: UInt64) {
        currentScrollbackRowSpaceRevision = revision
    }

    private func notificationScrollRestoreHasInvalidatedReplayGeometry(
        _ position: TerminalNotificationScrollPosition
    ) -> Bool {
        guard position.row > 0,
              let currentRevision = currentScrollbackRowSpaceRevision else { return false }
        if let replayGeneration = sessionScrollbackReplayGeneration,
           position.replayGeneration != replayGeneration {
            guard let markerRevision = sessionScrollbackReplayCompletionRowSpaceRevision else {
                return false
            }
            return currentRevision != markerRevision
        }
        guard let capturedRevision = position.rowSpaceRevision else { return false }
        return currentRevision != capturedRevision
    }

    func notificationScrollRestoreTarget(
        _ position: TerminalNotificationScrollPosition?,
        scrollbar suppliedScrollbar: GhosttyScrollbar? = nil
    ) -> TerminalNotificationScrollRestoreTarget? {
        guard let position else { return nil }
        if position.row <= 0 {
            return .bottom
        }
        guard let scrollbar = suppliedScrollbar ?? surfaceView.scrollbar else { return nil }
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
