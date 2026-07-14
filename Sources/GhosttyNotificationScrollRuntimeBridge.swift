import Foundation
import CmuxTerminal

extension TerminalPanel {
    func performInternalBindingAction(_ action: String) -> Bool {
        guard !isAgentHibernated else { return false }
        return surface.performInternalBindingAction(action)
    }
}

extension GhosttyApp {
    func handleCurrentDirectoryAction(_ directory: String, actionSequence: UInt64, surfaceView: GhosttyNSView) {
        let terminalSurface = surfaceView.terminalSurface
        DispatchQueue.main.async {
            if terminalSurface?.hostedView.sessionScrollbackReplayDidReceiveBoundary(
                directory,
                actionSequence: actionSequence
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
    func nextTerminalActionSequence() -> UInt64 {
        _scrollbarLock.lock()
        _terminalActionSequence &+= 1
        let sequence = _terminalActionSequence
        _scrollbarLock.unlock()
        return sequence
    }

    func flushPendingScrollbarIfAvailable() -> Bool {
        _scrollbarLock.lock()
        let hasPending = _pendingScrollbar != nil
        _scrollbarLock.unlock()
        guard hasPending else { return false }
        flushPendingScrollbar()
        return true
    }

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
