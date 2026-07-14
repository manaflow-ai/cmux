import Foundation
import CmuxTerminal

extension TerminalPanel {
    func performInternalBindingAction(_ action: String) -> Bool {
        guard !isAgentHibernated else { return false }
        return surface.performInternalBindingAction(action)
    }
}

extension GhosttyApp {
    func handleCurrentDirectoryAction(
        _ directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        surfaceView: GhosttyNSView
    ) {
        let terminalSurface = surfaceView.terminalSurface
        performOnMain {
            if terminalSurface?.hostedView.sessionScrollbackReplayDidReceiveBoundary(
                directory,
                authoritativeGeometry: authoritativeGeometry
            ) == true {
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

}
