import CmuxAuthRuntime
import CmuxIrxTransport
import Foundation

extension MobileHostIrxRuntime {
    /// The registry owns outgoing sessions; this runtime owns their shared v2
    /// endpoint. Account-directory clients are account-scoped; the rollback
    /// client stays pinned to the team that created it until the registry has
    /// replaced it.
    func makeDeviceClient(identity: AuthenticatedSessionIdentity, teamID: String?) -> DeviceIrxClient? {
        guard DevicesFeature.isEnabled else { return nil }
        let accountDirectoryEnabled = AccountMacDirectoryFeature.isEnabled()
        let client = DeviceIrxClient(context: { [weak self] in
            guard let self else { throw DeviceLinkError.notConnected }
            return try await self.deviceClientContext(
                identity: identity, teamID: teamID, accountDirectoryEnabled: accountDirectoryEnabled)
        }, journal: Self.journal)
        outgoingDeviceClient = client
        return client
    }

    /// Reads only the active account's v2 control service; no second registration occurs.
    func deviceClientContext(
        identity: AuthenticatedSessionIdentity,
        teamID: String? = nil,
        accountDirectoryEnabled: Bool = AccountMacDirectoryFeature.isEnabled()
    ) async throws -> DeviceIrxClientContext {
        guard DevicesFeature.isEnabled else { throw DeviceLinkError.notConnected }
        await activationTask?.value
        guard accountDirectoryEnabled == AccountMacDirectoryFeature.isEnabled(),
              Self.isDeviceClientScopeCurrent(
                  currentSession: auth?.authenticatedSessionIdentity, resolvedTeamID: auth?.resolvedTeamID,
                  identity: identity, teamID: teamID,
                  accountDirectoryEnabled: accountDirectoryEnabled),
              isNetworkingAllowed, let control = controlService,
              let supervisor = endpointSupervisor, let device = cachedState?.device else { throw DeviceLinkError.notConnected }
        let generation = generationToken
        let account = accountDirectoryClient
        return DeviceIrxClientContext(control: control, supervisor: supervisor, localDevice: device,
            allowsDirectPaths: Self.pathMode == .automatic,
            isCurrent: { @MainActor [weak self] in
                self?.generationToken == generation && DevicesFeature.isEnabled
                    && accountDirectoryEnabled == AccountMacDirectoryFeature.isEnabled()
                    && Self.isDeviceClientScopeCurrent(
                        currentSession: self?.auth?.authenticatedSessionIdentity,
                        resolvedTeamID: self?.auth?.resolvedTeamID,
                        identity: identity, teamID: teamID,
                        accountDirectoryEnabled: accountDirectoryEnabled)
                    && self?.isNetworkingAllowed == true
            },
            accountDirectory: { [weak account] in
                // The remote flag off restores team-only discovery and dialing.
                guard accountDirectoryEnabled, AccountMacDirectoryFeature.isEnabled(), let account else { return nil }
                return await account.snapshot()
            })
    }

    nonisolated static func isDeviceClientScopeCurrent(
        currentSession: AuthenticatedSessionIdentity?,
        resolvedTeamID: String?,
        identity: AuthenticatedSessionIdentity,
        teamID: String?,
        accountDirectoryEnabled: Bool
    ) -> Bool {
        guard currentSession == identity else { return false }
        return accountDirectoryEnabled || resolvedTeamID == teamID
    }
}
