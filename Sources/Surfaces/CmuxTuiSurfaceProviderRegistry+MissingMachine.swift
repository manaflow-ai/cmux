import CmuxCloud

extension CmuxTuiSurfaceProviderRegistry {
    /// Retires one missing machine and clears the caller's local bindings first.
    func machineWasDeleted(
        _ rawID: String,
        closeLocalWorkspaces: (@MainActor (String) -> Void)? = nil
    ) {
        (closeLocalWorkspaces ?? { AppDelegate.shared?.closeLocalWorkspaces(forCloudVMID: $0) })(rawID)
        refreshGeneration &+= 1
        unregisterMachine(rawID)
    }

    /// Retires several missing machines after one local workspace scan.
    func machineWasDeleted(
        _ rawIDs: Set<String>,
        closeLocalWorkspaces: (@MainActor (Set<String>) -> Void)? = nil,
        invalidatesRefresh: Bool = true
    ) {
        (closeLocalWorkspaces ?? { AppDelegate.shared?.closeLocalWorkspaces(forCloudVMIDs: $0) })(rawIDs)
        if invalidatesRefresh { refreshGeneration &+= 1 }
        let candidates = Set(providers.keys).union(machineTeardowns.keys).union(pendingMachineCreationIDs)
        let resolved = Dictionary(candidates.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for rawID in rawIDs {
            unregisterMachine(resolved[rawID.lowercased()] ?? rawID, alreadyResolved: true)
        }
    }

    /// The provider callback is the shared terminal disposition for a typed
    /// `vm_not_found`: close local bindings before unregistering the provider.
    var missingMachineHandler: @MainActor (String, CloudVMHTTPError) -> Void {
        { [weak self] machineID, _ in self?.machineWasDeleted(machineID) }
    }

}
