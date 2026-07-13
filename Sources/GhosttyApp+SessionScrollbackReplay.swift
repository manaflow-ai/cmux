@MainActor
extension GhosttyApp {
    func completeSessionScrollbackReplayIfNeeded(
        surfaceView: GhosttyNSView,
        reportedDirectory: String,
        scrollbarAtMarker: GhosttyScrollbar
    ) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        return terminalSurface.hostedView.completeSessionScrollbackReplay(
            ifMatches: reportedDirectory,
            scrollbarAtMarker: scrollbarAtMarker
        )
    }
}
