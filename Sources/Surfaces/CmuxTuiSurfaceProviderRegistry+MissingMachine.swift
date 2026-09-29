import CmuxCloud

extension CmuxTuiSurfaceProviderRegistry {
    /// The provider callback is the shared terminal disposition for a typed
    /// `vm_not_found`: close local bindings before unregistering the provider.
    var missingMachineHandler: @MainActor (String, CloudVMHTTPError) -> Void {
        { [weak self] machineID, _ in self?.machineWasDeleted(machineID) }
    }

    func retireMissingMachine(_ rawID: String) {
        machineWasDeleted(rawID)
    }
}
