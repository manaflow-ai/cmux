import CmuxTerminalCore
import GhosttyKit

extension GhosttyApp {
    func completeSessionScrollbackReplayIfNeeded(
        surfaceView: GhosttyNSView,
        action: ghostty_action_pwd_s
    ) -> Bool {
        let reportedDirectory = action.pwd.flatMap { String(cString: $0) } ?? ""
        guard SessionScrollbackReplayCompletionMarker.isReservedReportedDirectory(reportedDirectory) else {
            return false
        }
        // The action pointer is callback-scoped, so copy it before hopping
        // to MainActor through performOnMain.
        let scrollbarAtMarker = action.scrollbar.map { GhosttyScrollbar(c: $0.pointee) }
        let scrollbarRevisionAtMarker = action.scrollbar_revision
        return performOnMain {
            completeSessionScrollbackReplayIfNeeded(
                surfaceView: surfaceView,
                reportedDirectory: reportedDirectory,
                scrollbarAtMarker: scrollbarAtMarker,
                scrollbarRevisionAtMarker: scrollbarRevisionAtMarker
            )
        }
    }

    @MainActor
    func completeSessionScrollbackReplayIfNeeded(
        surfaceView: GhosttyNSView,
        reportedDirectory: String,
        scrollbarAtMarker: GhosttyScrollbar?,
        scrollbarRevisionAtMarker: UInt64
    ) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        return terminalSurface.hostedView.completeSessionScrollbackReplay(
            ifMatches: reportedDirectory,
            scrollbarAtMarker: scrollbarAtMarker,
            scrollbarRevisionAtMarker: scrollbarRevisionAtMarker
        )
    }
}
