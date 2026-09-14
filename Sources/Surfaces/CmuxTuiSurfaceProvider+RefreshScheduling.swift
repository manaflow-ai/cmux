import Foundation

/// Schedules provider graph reads without dropping a pane-registration edge.
@MainActor
extension CmuxTuiSurfaceProvider {
    /// Requests one coalesced graph refresh for this provider.
    func scheduleRefresh() {
        let lifecycle = lifecycleGeneration
        guard scheduledRefresh == nil else {
            refreshRequestedWhileScheduled = true
            refreshCoordinator.invalidate()
            return
        }
        refreshRequestedWhileScheduled = false
        scheduledRefresh = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.scheduledRefresh = nil
                    if self.refreshRequestedWhileScheduled,
                       self.lifecycleGeneration == lifecycle,
                       self.isRegisteredInCatalog() {
                        self.refreshRequestedWhileScheduled = false
                        self.scheduleRefresh()
                    } else {
                        self.refreshRequestedWhileScheduled = false
                    }
                }
            }
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            guard self.lifecycleGeneration == lifecycle, self.isRegisteredInCatalog() else { return }
            let established = await self.refreshCurrentGraph(force: false)
            guard !established,
                  self.info.linkState == .error || self.info.linkState == .unavailable else { return }
            for session in self.manualMirrorSessions.values
            where session.remoteSurfaceID == 0 && session.phase == .idle {
                session.markSurfaceResolutionUnavailable(
                    reason: .unresolved("the Cloud endpoint is unavailable")
                )
            }
        }
    }
}
