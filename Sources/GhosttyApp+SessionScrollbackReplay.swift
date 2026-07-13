import GhosttyKit

@MainActor
extension GhosttyApp {
    func completeSessionScrollbackReplayIfNeeded(
        surfaceView: GhosttyNSView,
        reportedDirectory: String
    ) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface,
              let surface = terminalSurface.surface else { return false }
        return terminalSurface.hostedView.completeSessionScrollbackReplay(
            ifMatches: reportedDirectory,
            authoritativeScrollbar: GhosttyScrollbar(c: ghostty_surface_scrollbar(surface))
        )
    }
}
