import Foundation
import CmuxTerminal

extension TerminalPanel {
    func performInternalBindingAction(_ action: String) -> Bool {
        guard !isAgentHibernated else { return false }
        return surface.performBindingAction(action)
    }
}

extension GhosttyApp {
    func handleCurrentDirectoryAction(_ directory: String, surfaceView: GhosttyNSView) {
        let terminalSurface = surfaceView.terminalSurface
        DispatchQueue.main.async {
            if terminalSurface?.hostedView.sessionScrollbackReplayDidReceiveBoundary(directory) == true {
                return
            }
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
    static func retainRenderedFrameNotifications() -> () -> Void {
        // See GhosttyApp.retainTickNotifications() on the idempotent release.
        let retention = GhosttyApp.renderedFrameNotificationDemand.retain()
        return { retention.release() }
    }

    func retainTargetedRenderedFrameNotifications() -> () -> Void {
        let retention = targetedRenderedFrameNotificationDemand.retain()
        return { retention.release() }
    }

    var hasRenderedFrameNotificationDemand: Bool {
        GhosttyApp.renderedFrameNotificationDemand.isActive ||
            targetedRenderedFrameNotificationDemand.isActive
    }

    func currentRenderedFrameSourceGeneration() -> UInt64 {
        (layer as? GhosttyMetalLayer)?.currentFrameGeneration() ?? 0
    }
}
