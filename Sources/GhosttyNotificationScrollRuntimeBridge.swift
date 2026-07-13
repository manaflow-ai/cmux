import Foundation

extension GhosttyApp {
    func handleCurrentDirectoryAction(_ directory: String, surfaceView: GhosttyNSView) {
        let terminalSurface = surfaceView.terminalSurface
        if performOnMain({
            terminalSurface?.hostedView.sessionScrollbackReplayDidReceiveBoundary(directory) == true
        }) { return }

        DispatchQueue.main.async {
            guard let tabId = surfaceView.tabId,
                  let surfaceId = terminalSurface?.id else { return }
            AppDelegate.shared?.tabManagerFor(tabId: tabId)?.updateReportedSurfaceDirectory(
                tabId: tabId,
                surfaceId: surfaceId,
                directory: directory
            )
        }
    }
}

extension GhosttyNSView {
    func currentRenderedFrameSourceGeneration() -> UInt64 {
        (layer as? GhosttyMetalLayer)?.currentFrameGeneration() ?? 0
    }
}
