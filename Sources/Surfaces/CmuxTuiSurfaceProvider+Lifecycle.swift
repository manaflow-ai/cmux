import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    /// Retire synchronously, then join mutations before releasing shared transport access.
    func stop() async {
        suspendForFeatureFlag()
        await terminalMutationQueue.waitForIdle()
        await portAccessStore.remove(machineID: machineID)
    }
}
