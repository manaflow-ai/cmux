import Foundation

extension TerminalSurface {
    /// Clears hibernation state when no native surface was ever realized.
    @MainActor
    func suspendRuntimeSurfaceWithoutNativeSurface(reason: String) -> Bool {
        let isNewHibernation = !runtimeSurfaceSuspendedForAgentHibernation
        let hasRetainedRuntimeResources = surfaceCallbackContext != nil ||
            manualIOContext != nil ||
            mobileByteTeeLease != nil
        if let reservation = agentHibernationRuntimeTeardownReservation {
            agentHibernationRuntimeTeardownReservation = nil
            runtimeTeardown.cancelIsolatedHibernationTeardown(reservation)
        }
        if isNewHibernation {
            // Hibernation retires the terminal and portal generations even
            // when there is no native surface. Delayed hook reports and
            // queued portal-host retries must not target the dormant model.
            advanceTerminalLifecycleForRuntimeReplacement()
            portalLifecycleGeneration &+= 1
            pendingSocketInputQueue.removeAll(keepingCapacity: false)
            pendingSocketInputBytes = 0
            desiredFocusState = false
        }
        activePortalHostLease = nil
        portalHostAuthority = nil
        clearPortalHostVacancyRetries()
        runtimeSurfaceSuspendedForAgentHibernation = true
        mobileViewportFontFitState = nil
        backgroundSurfaceStartQueued = false
        backgroundSurfaceStartSource = .normal
        cancelAgentCommandShimInstallLifecycle()
        closeHeadlessStartupWindowIfNeeded()
        if isNewHibernation || hasRetainedRuntimeResources {
            retireRuntimeResourcesWithoutSurface(reason: reason)
        }
        return true
    }
}
