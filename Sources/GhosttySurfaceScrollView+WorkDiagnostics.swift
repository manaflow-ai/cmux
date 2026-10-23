import CMUXMobileCore
import Foundation

extension GhosttySurfaceScrollView {
    /// Returns whether revealing a portal needs the fallback synchronous refresh.
    /// A frame may have been presented before the pane was hidden, while the
    /// renderer is no longer presented when the workspace becomes visible again.
    /// Use current renderer health so that stale warm-frame state cannot suppress
    /// the recovery redraw.
    static func shouldScheduleVisibilityRevealRefresh(rendererPresented: Bool) -> Bool {
        !rendererPresented
    }

    /// Request an immediate terminal redraw after geometry updates so stale IOSurface
    /// contents do not remain stretched during live resize churn.
    func refreshSurfaceNow(reason: String, transition: TerminalWorkContext.Transition) {
        TerminalGeometryDiagnostics().refresh(self, reason: reason, transition: transition)
    }

    func scheduleVisibilityRevealRefresh(transition: TerminalWorkContext.Transition) {
        if transition != .unknown { pendingVisibilityRefreshTransition = transition }
        guard !hasVisibilityRevealRefreshScheduled else { return }
        hasVisibilityRevealRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasVisibilityRevealRefreshScheduled = false
            let transition = self.pendingVisibilityRefreshTransition
            self.pendingVisibilityRefreshTransition = .unknown
            guard self.isVisibleInUI else { return }
            guard self.surfaceView.terminalSurface?.isRendererPresented != true else { return }
            self.refreshSurfaceNow(reason: "setVisibleInUI.deferred", transition: transition)
        }
    }

}
