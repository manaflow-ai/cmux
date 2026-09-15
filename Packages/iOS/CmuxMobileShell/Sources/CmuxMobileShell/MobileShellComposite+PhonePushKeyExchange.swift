import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel

@MainActor
extension MobileShellComposite {
    /// Runs only after the caller has passed the existing authenticated Mac
    /// identity gate. Hooke owns descriptor creation and persistence.
    func exchangePhonePushKeyIfConfigured(
        client: MobileCoreRPCClient,
        status: MobileHostStatusResponse
    ) async {
        guard let hooks = phonePushKeyExchangeHooks,
              let accountID = identityProvider?.currentUserID,
              let macDeviceID = status.macDeviceID,
              let macInstanceTag = status.macInstanceTag,
              let macBuildID = status.macClientNamespace else {
            return
        }
        do {
            let exchange = try await client.exchangePhonePushKey(
                hooks: hooks,
                clientID: clientID
            )
            let response = exchange.response
            guard identityProvider?.currentUserID == accountID,
                  response.accountID == accountID,
                  response.macDeviceID == macDeviceID,
                  response.macInstanceTag == macInstanceTag,
                  response.macBuildID == macBuildID else {
                return
            }
            let context = MobilePhonePushKeyExchangeContext(
                accountID: accountID,
                teamID: response.teamID,
                clientID: clientID,
                iosBuildID: exchange.request.iosBuildID,
                iosInstallationID: exchange.request.descriptor.installationID,
                macDeviceID: response.macDeviceID,
                macInstanceTag: response.macInstanceTag,
                macBuildID: response.macBuildID
            )
            await hooks.pinPeerDescriptor(response.descriptor, context)
        } catch {
            // Push key exchange is additive to connection readiness. Existing
            // terminal RPC behavior remains available if the push hook fails.
        }
    }
}
