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

    /// Marks scoped-access loss unavailable while retaining local Cloud state.
    func machineBecameUnavailable(_ rawID: String) {
        machineBecameUnavailable([rawID])
    }

    /// Suspends attach work for scoped-access loss without deleting local state.
    func machineBecameUnavailable(_ rawIDs: Set<String>) {
        let candidates = Set(providers.keys).union(machineTeardowns.keys).union(pendingMachineCreationIDs)
        let resolved = Dictionary(candidates.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for rawID in rawIDs {
            let id = resolved[rawID.lowercased()] ?? rawID
            providers[id]?.suspendForFeatureFlag()
            catalog?.markCloudStateStale(on: SurfaceMachineID.cloud(id), reason: "cloud_scope_unavailable")
        }
    }

    /// Unregisters unbound machine rows after one normalized ownership lookup.
    func unregisterMachines(_ rawIDs: Set<String>) {
        let candidates = Set(providers.keys).union(machineTeardowns.keys).union(pendingMachineCreationIDs)
        let resolved = Dictionary(candidates.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for rawID in rawIDs {
            unregisterMachine(resolved[rawID.lowercased()] ?? rawID, alreadyResolved: true)
        }
    }

    /// The provider callback is the shared terminal disposition for a typed
    /// `vm_not_found`: close local bindings before unregistering the provider.
    var missingMachineHandler: @MainActor (String, CloudVMHTTPError) -> Void {
        { [weak self] machineID, _ in self?.machineBecameUnavailable(machineID) }
    }

}
