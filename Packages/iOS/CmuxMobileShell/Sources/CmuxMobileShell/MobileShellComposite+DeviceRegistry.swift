import CmuxMobileShellModel

@MainActor
extension MobileShellComposite {
    /// Reload ``registryDevices`` from the team-scoped device registry.
    ///
    /// Best-effort and failure-tolerant: a missing registry, an unauthorized
    /// call, or a malformed response leaves the current list untouched (so a
    /// transient blip never blanks a populated tree). Devices are sorted with the
    /// currently-connected one first, then by most-recently-seen, so the tree
    /// leads with the host the user is on. Mirrors ``loadPairedMacs()``: signed
    /// out yields an empty list.
    public func loadRegistryDevices() async {
        guard let deviceRegistry,
              let scope = await currentScopeSnapshot() else {
            registryDevices = []
            return
        }
        let outcome = await deviceRegistry.listDevices()
        let loaded: [RegistryDevice]
        switch outcome {
        case .ok(let devices):
            loaded = devices
        case .authRejected:
            // The registry is team-scoped and rejected the call on auth/scope
            // grounds (401/403): the cached list may be another scope's data, so
            // clear it. The tree falls back to local paired Macs via
            // `deviceTreeDevices`, so the sheet stays usable. Guarded on the
            // requesting user still being current (mirroring the `.ok` path):
            // a stale 401 from a signed-out session that lands after a
            // different user signed in must not blank the new user's tree.
            if await isScopeCurrent(scope) {
                registryDevices = []
            }
            return
        case .transientFailure:
            // Network blip / 5xx / malformed body: keep what we have rather than
            // blanking a populated tree on a transient failure.
            return
        }
        // The await above suspended the main actor; discard the result unless we
        // are still in the same signed-in account/team scope, so a slow load can
        // never repopulate another scope's devices after sign-out, account switch,
        // or same-account team switch.
        guard await isScopeCurrent(scope) else { return }
        let connectedID = connectedMacDeviceID
        let forgottenIDs = await forgottenMacDeviceIDs(scope: scope)
        guard await isScopeCurrent(scope) else { return }
        let pairedIDs = Set(pairedMacsForIdentityMatching.map { $0.macDeviceID.lowercased() })
        registryDevices = loaded.filter {
            !forgottenIDs.contains($0.deviceId)
                && (buildScope == nil || pairedIDs.contains($0.deviceId.lowercased()))
        }.sorted { lhs, rhs in
            let lhsConnected = lhs.deviceId == connectedID
            let rhsConnected = rhs.deviceId == connectedID
            if lhsConnected != rhsConnected { return lhsConnected }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
    }
}
