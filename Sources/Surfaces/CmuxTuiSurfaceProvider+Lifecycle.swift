import CmuxCloud
import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    var isAwake: Bool { summary.status == "running" }
    var providerID: String { summary.provider }
    /// Port rows are openable only when the machine advertises a preview
    /// capability or has the private route used by Freestyle.
    var capabilities: VMCapabilities { summary.capabilities }
    var supportsPortPreviews: Bool {
        capabilities.ports || summary.preferredPrivateAddress != nil
    }

    /// Retire synchronously, then join mutations before releasing shared transport access.
    func stop() async {
        suspendForFeatureFlag()
        await terminalMutationQueue.waitForIdle()
        await portAccessStore.remove(machineID: machineID)
    }

    /// Stops machine-bound activity while retaining this provider and its graph.
    /// The control plane may report the machine running again later.
    func stopTransportResources() {
        lifecycleGeneration &+= 1
        guestURLService?.stop()
        guestURLService = nil
        displayCoordinator.stop()
        portDiscovery.invalidate()
        refreshCoordinator.cancel()
        CloudNotificationSyncHub.shared.unregister(machineID: machineID)
        notificationSync?.retire()
        notificationSync = nil
        if let notificationPlacementObserver {
            NotificationCenter.default.removeObserver(notificationPlacementObserver)
            self.notificationPlacementObserver = nil
        }
        changeWatcher?.cancel()
        changeWatcher = nil
        watchedLink = nil
        changeWatcherID = nil
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        stateRecoveryRefreshTask?.cancel()
        stateRecoveryRefreshTask = nil
        stateRecoveryRefreshQueued = false
        for session in manualMirrorSessions.values { session.stop() }
        manualMirrorSessions.removeAll()
        for task in remoteTerminalProjectionTasks.values { task.cancel() }
        remoteTerminalProjectionTasks.removeAll()
    }
}
