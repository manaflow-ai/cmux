public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Reload ``registryDevices`` from the account-scoped device registry.
    @discardableResult
    public func loadRegistryDevices() async -> MobileRegistryLoadResult {
        guard let deviceRegistry,
              let scope = await currentScopeSnapshot() else {
            registryDevices = []
            return .unavailable
        }
        let outcome = await deviceRegistry.listDevices()
        let loaded: [RegistryDevice]
        switch outcome {
        case .ok(let devices):
            loaded = devices
        case .authRejected:
            guard await isScopeCurrent(scope) else { return .unavailable }
            registryDevices = []
            return .authRejected
        case .transientFailure:
            return .unavailable
        }

        guard await isScopeCurrent(scope) else { return .unavailable }
        let connectedID = connectedMacDeviceID
        let forgottenIDs = await forgottenMacDeviceIDs(scope: scope)
        guard await isScopeCurrent(scope) else { return .unavailable }
        registryDevices = loaded.filter { !forgottenIDs.contains($0.deviceId) }.sorted { lhs, rhs in
            let lhsConnected = lhs.deviceId == connectedID
            let rhsConnected = rhs.deviceId == connectedID
            if lhsConnected != rhsConnected { return lhsConnected }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
        return .loaded
    }

    /// Prefer account registry devices, then synthesize rows from paired Macs.
    public var deviceTreeDevices: [RegistryDevice] {
        if !registryDevices.isEmpty { return registryDevices }
        let connectedID = connectedMacDeviceID
        return pairedMacs
            .map { mac in
                RegistryDevice(
                    deviceId: mac.macDeviceID,
                    platform: "mac",
                    displayName: mac.displayName,
                    lastSeenAt: mac.lastSeenAt,
                    instances: [
                        RegistryAppInstance(
                            tag: "default",
                            routes: mac.routes,
                            lastSeenAt: mac.lastSeenAt
                        )
                    ]
                )
            }
            .sorted { lhs, rhs in
                let lhsConnected = lhs.deviceId == connectedID
                let rhsConnected = rhs.deviceId == connectedID
                if lhsConnected != rhsConnected { return lhsConnected }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
    }

    /// Prepare a disconnected-root handoff while keeping failure presentation
    /// scoped to the account and team that started it.
    public func prepareRegistrySessionHandoff(
        deviceID: String,
        instanceTag: String,
        sessionID: String
    ) async -> MobileWorkspacePreview.ID? {
        guard let scope = await currentScopeSnapshot() else { return nil }
        isRegistryHandoffFailurePresented = false
        guard let session = registryDevices
            .first(where: { $0.deviceId == deviceID })?
            .instances.first(where: { $0.tag == instanceTag })?
            .sessions.first(where: { $0.id == sessionID }) else {
            await presentRegistryHandoffFailure(ifScopeCurrent: scope)
            return nil
        }
        let workspaceID = await prepareRegistrySessionHandoff(
            deviceID: deviceID,
            instanceTag: instanceTag,
            sessionID: sessionID,
            agentSessionID: session.agentSessionID
        )
        guard await isScopeCurrent(scope) else { return nil }
        guard let workspaceID else {
            await presentRegistryHandoffFailure(ifScopeCurrent: scope)
            return nil
        }
        return workspaceID
    }

    private func presentRegistryHandoffFailure(
        ifScopeCurrent scope: MobileShellScopeSnapshot
    ) async {
        guard await isScopeCurrent(scope) else { return }
        isRegistryHandoffFailurePresented = true
    }

    public func dismissRegistryHandoffFailure() {
        isRegistryHandoffFailurePresented = false
    }
}
