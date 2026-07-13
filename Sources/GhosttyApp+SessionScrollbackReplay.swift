@MainActor
extension GhosttyApp {
    func completeSessionScrollbackReplayIfNeeded(
        surfaceView: GhosttyNSView,
        reportedDirectory: String
    ) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        return terminalSurface.hostedView.completeSessionScrollbackReplay(
            ifMatches: reportedDirectory
        )
    }
}
