public import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    /// Reload ``registryDevices`` from the current team's device registry.
    ///
    /// Devices and routes are team-scoped. The service filters each device's
    /// live-session summaries to the authenticated account before returning them.
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

    /// Prefer team registry devices, then synthesize rows from paired Macs.
    ///
    /// Registry device and route records are shared by the team, while their
    /// live-session arrays contain only sessions visible to this account.
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

    /// Prepare a request-owned handoff while keeping navigation, rollback, and
    /// failure presentation scoped to the account and team that started it.
    public func prepareRegistrySessionHandoff(
        deviceID: String,
        instanceTag: String,
        sessionID: String,
        expectedAgentSessionID: String?
    ) async -> MobileWorkspacePreview.ID? {
        let requestID = beginRegistrySessionHandoffAttempt()
        defer { finishRegistrySessionHandoffAttempt(requestID) }
        isRegistryHandoffFailurePresented = false
        guard let scope = await currentScopeSnapshot() else { return nil }
        guard !Task.isCancelled,
              await isRegistrySessionHandoffAttemptCurrent(requestID, scope: scope),
              !Task.isCancelled else {
            return nil
        }
        guard let session = registryDevices
            .first(where: { $0.deviceId == deviceID })?
            .instances.first(where: { $0.tag == instanceTag })?
            .sessions.first(where: { $0.id == sessionID }),
              session.agentSessionID == expectedAgentSessionID else {
            await presentRegistryHandoffFailure(requestID: requestID, ifScopeCurrent: scope)
            return nil
        }
        let workspaceID = await prepareRegistrySessionHandoff(
            deviceID: deviceID,
            instanceTag: instanceTag,
            sessionID: sessionID,
            agentSessionID: expectedAgentSessionID,
            ifStillCurrent: { [weak self] in
                self?.isRegistrySessionHandoffAttemptCurrent(requestID) == true
            }
        )
        guard !Task.isCancelled,
              await isRegistrySessionHandoffAttemptCurrent(requestID, scope: scope),
              !Task.isCancelled else {
            return nil
        }
        guard let workspaceID else {
            await presentRegistryHandoffFailure(requestID: requestID, ifScopeCurrent: scope)
            return nil
        }
        guard await completeRegistrySessionHandoffNavigation(
            workspaceID: workspaceID,
            requestID: requestID,
            scope: scope
        ) else { return nil }
        return workspaceID
    }

    func beginRegistrySessionHandoffAttempt() -> UUID {
        invalidateRegistrySessionHandoffAttempt()
        let requestID = UUID()
        registrySessionHandoffAttemptID = requestID
        isRegistrySessionHandoffInProgress = true
        return requestID
    }

    func isRegistrySessionHandoffAttemptCurrent(_ requestID: UUID) -> Bool {
        registrySessionHandoffAttemptID == requestID && isSignedIn
    }

    func isRegistrySessionHandoffAttemptCurrent(
        _ requestID: UUID,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard isRegistrySessionHandoffAttemptCurrent(requestID) else { return false }
        let scopeIsCurrent = await isScopeCurrent(scope)
        return scopeIsCurrent && isRegistrySessionHandoffAttemptCurrent(requestID)
    }

    func finishRegistrySessionHandoffAttempt(_ requestID: UUID) {
        guard registrySessionHandoffAttemptID == requestID else { return }
        registrySessionHandoffAttemptID = nil
        isRegistrySessionHandoffInProgress = false
    }

    func invalidateRegistrySessionHandoffAttempt() {
        registrySessionHandoffAttemptID = nil
        isRegistrySessionHandoffInProgress = false
        deeplinkWorkspaceNavigationRequest = nil
        registrySessionHandoffNavigationRequest = nil
    }

    public func selectWorkspaceFromUserAction(_ id: MobileWorkspacePreview.ID) {
        invalidateRegistrySessionHandoffAttempt()
        selectedWorkspaceID = id
    }

    @discardableResult
    func completeRegistrySessionHandoffNavigation(
        workspaceID: MobileWorkspacePreview.ID,
        requestID: UUID,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard !Task.isCancelled,
              await isRegistrySessionHandoffAttemptCurrent(requestID, scope: scope),
              !Task.isCancelled else {
            return false
        }
        selectedWorkspaceID = workspaceID
        deeplinkWorkspaceNavigationRequest = DeeplinkWorkspaceNavigationRequest(
            token: UUID(),
            workspaceID: workspaceID
        )
        return true
    }

    private func presentRegistryHandoffFailure(
        requestID: UUID,
        ifScopeCurrent scope: MobileShellScopeSnapshot
    ) async {
        guard !Task.isCancelled,
              await isRegistrySessionHandoffAttemptCurrent(requestID, scope: scope),
              !Task.isCancelled else { return }
        isRegistryHandoffFailurePresented = true
    }

    public func dismissRegistryHandoffFailure() {
        isRegistryHandoffFailurePresented = false
    }
}
