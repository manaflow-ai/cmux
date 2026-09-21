import CMUXMobileCore
import Foundation

extension GhosttySurfaceScrollView {
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
            self.refreshSurfaceNow(reason: "setVisibleInUI.deferred", transition: transition)
        }
    }

}
