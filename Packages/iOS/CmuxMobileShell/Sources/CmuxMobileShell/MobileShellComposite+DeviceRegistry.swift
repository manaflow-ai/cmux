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
            if await isScopeCurrent(scope) {
                registryDevices = []
            }
            return .unavailable
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

    /// Attach to an advertised registry session, then resolve its live workspace.
    public func prepareRegistrySessionHandoff(
        deviceID: String,
        instanceTag: String,
        sessionID: String
    ) async -> MobileWorkspacePreview.ID? {
        isRegistryHandoffFailurePresented = false
        guard let device = registryDevices.first(where: { $0.deviceId == deviceID }),
              let instance = device.instances.first(where: { $0.tag == instanceTag }),
              let session = instance.sessions.first(where: { $0.id == sessionID }) else {
            isRegistryHandoffFailurePresented = true
            return nil
        }

        await connectToRegistryInstance(device: device, instance: instance)
        guard connectionState == .connected,
              connectedMacDeviceID == device.deviceId,
              activeMacInstanceTag == instance.tag else {
            isRegistryHandoffFailurePresented = true
            return nil
        }
        let authoritativeRefreshSucceeded = await refreshWorkspaces()
        guard let workspaceID = Self.registryHandoffWorkspaceID(
            workspaceID: session.workspaceID,
            deviceID: device.deviceId,
            workspaces: workspaces,
            authoritativeRefreshSucceeded: authoritativeRefreshSucceeded
        ) else {
            await loadRegistryDevices()
            isRegistryHandoffFailurePresented = true
            return nil
        }
        if let terminalID = session.terminalID,
           let workspace = workspaces.first(where: { $0.id == workspaceID }),
           let terminal = workspace.terminals.first(where: { $0.id.rawValue == terminalID }) {
            selectTerminal(terminal.id)
        }
        return workspaceID
    }

    public func dismissRegistryHandoffFailure() {
        isRegistryHandoffFailurePresented = false
    }

    /// Resolve a runtime-local workspace without crossing Mac ownership.
    static func registryHandoffWorkspaceID(
        workspaceID: String,
        deviceID: String,
        workspaces: [MobileWorkspacePreview],
        authoritativeRefreshSucceeded: Bool = true
    ) -> MobileWorkspacePreview.ID? {
        guard authoritativeRefreshSucceeded else { return nil }
        return workspaces.first { workspace in
            workspace.rpcWorkspaceID.rawValue == workspaceID
                && workspace.macDeviceID == deviceID
        }?.id
    }
}
