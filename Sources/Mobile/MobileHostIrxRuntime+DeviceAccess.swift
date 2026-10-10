import CmuxAuthRuntime
import CmuxIrxTransport
import Foundation

extension MobileHostIrxRuntime {
    /// The registry owns outgoing sessions; this runtime owns their shared v2
    /// endpoint. `teamID` remains in the composition signature for callers
    /// that also construct the team-scoped host, but outgoing device access is
    /// account-scoped.
    func makeDeviceClient(identity: AuthenticatedSessionIdentity, teamID _: String?) -> DeviceIrxClient? {
        guard DevicesFeature.isEnabled else { return nil }
        let client = DeviceIrxClient(context: { [weak self] in
            guard let self else { throw DeviceLinkError.notConnected }
            return try await self.deviceClientContext(identity: identity)
        }, journal: Self.journal)
        outgoingDeviceClient = client
        return client
    }

    /// Reads only the active account's v2 control service; no second registration occurs.
    func deviceClientContext(identity: AuthenticatedSessionIdentity) async throws -> DeviceIrxClientContext {
        guard DevicesFeature.isEnabled else { throw DeviceLinkError.notConnected }
        await activationTask?.value
        guard auth?.authenticatedSessionIdentity == identity,
              isNetworkingAllowed, let control = controlService,
              let supervisor = endpointSupervisor, let device = cachedState?.device else { throw DeviceLinkError.notConnected }
        let generation = generationToken
        let account = accountDirectoryClient
        return DeviceIrxClientContext(control: control, supervisor: supervisor, localDevice: device,
            allowsDirectPaths: Self.pathMode == .automatic,
            isCurrent: { @MainActor [weak self] in
                self?.generationToken == generation && DevicesFeature.isEnabled
                    && self?.auth?.authenticatedSessionIdentity == identity
                    && self?.isNetworkingAllowed == true
            },
            accountDirectory: { [weak account] in
                // The remote flag off restores team-only discovery and dialing.
                guard AccountMacDirectoryFeature.isEnabled(), let account else { return nil }
                return await account.snapshot()
            })
    }
}
