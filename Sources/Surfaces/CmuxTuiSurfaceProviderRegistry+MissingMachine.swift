import CmuxCloud

extension CmuxTuiSurfaceProviderRegistry {
    /// The provider callback is the shared terminal disposition for a typed
    /// `vm_not_found`: close local bindings before unregistering the provider.
    var missingMachineHandler: @MainActor (String, CloudVMHTTPError) -> Void {
        { [weak self] machineID, _ in self?.machineWasDeleted(machineID) }
    }

    /// Fleet listing is authoritative only after it succeeds. A missing ID in
    /// that page gets the same local cleanup as an attach-time `vm_not_found`.
    fileprivate func retireMissingMachine(_ rawID: String) {
        AppDelegate.shared?.closeLocalWorkspaces(forCloudVMID: rawID)
        unregisterMachine(rawID)
    }
}
