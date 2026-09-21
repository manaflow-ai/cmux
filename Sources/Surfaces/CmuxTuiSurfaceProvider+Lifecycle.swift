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
}
