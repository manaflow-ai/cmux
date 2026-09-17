import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import OSLog

private let phonePushKeyExchangeLog = Logger(
    subsystem: "ai.manaflow.cmux",
    category: "phone-push-key-exchange"
)

@MainActor
extension MobileShellComposite {
    /// Starts optional push setup after attachment. Only the owned task waits
    /// for key exchange; terminal readiness never depends on push support.
    func exchangePhonePushKeyIfConfigured(
        client: MobileCoreRPCClient,
        status: MobileHostStatusResponse
    ) {
        phonePushKeyExchangeRetryTask?.cancel()
        phonePushKeyExchangeRetryTask = nil
        guard status.capabilities.contains(Self.phonePushKeyExchangeCapability) else {
            diagnosticLog?.recordAppEvent(.pushKeyExchangeUnsupported, failure: .unsupportedRoute)
            return
        }
        guard phonePushKeyExchangeHooks != nil,
              let accountID = identityProvider?.currentUserID,
              !accountID.isEmpty,
              let macDeviceID = status.macDeviceID,
              let macInstanceTag = status.macInstanceTag,
              let macBuildID = status.macClientNamespace else {
            diagnosticLog?.recordAppEvent(.pushKeyExchangeContextMissing, failure: .credentialUnavailable)
            return
        }
        phonePushKeyExchangeRetryTask = Task { @MainActor [weak self, client] in
            for retry in 0..<3 {
                guard !Task.isCancelled, let self,
                      self.identityProvider?.currentUserID == accountID else { return }
                let exchanged = await self.performPhonePushKeyExchange(
                    client: client,
                    accountID: accountID,
                    macDeviceID: macDeviceID,
                    macInstanceTag: macInstanceTag,
                    macBuildID: macBuildID
                )
                guard !Task.isCancelled, self.identityProvider?.currentUserID == accountID else { return }
                if exchanged {
                    self.diagnosticLog?.recordAppEvent(.pushKeyExchangeSucceeded)
                    return
                }
                guard retry < 2 else { break }
                try? await Task.sleep(for: .seconds(1 << retry))
            }
            guard !Task.isCancelled, let self else { return }
            self.diagnosticLog?.recordAppEvent(.pushKeyExchangeFailed, failure: .secureChannelFailed)
            phonePushKeyExchangeLog.error("key exchange failed; reconnect or reopen the app to retry secure push setup")
        }
    }

    private func performPhonePushKeyExchange(
        client: MobileCoreRPCClient,
        accountID: String,
        macDeviceID: String,
        macInstanceTag: String,
        macBuildID: String
    ) async -> Bool {
        guard let hooks = phonePushKeyExchangeHooks else { return false }
        for attempt in 0..<3 {
            guard !Task.isCancelled, identityProvider?.currentUserID == accountID else { return false }
            do {
                let exchange = try await client.exchangePhonePushKey(
                    hooks: hooks,
                    clientID: clientID
                )
                let response = exchange.response
                guard !Task.isCancelled,
                      identityProvider?.currentUserID == accountID,
                      response.accountID == accountID,
                      response.macDeviceID == macDeviceID,
                      response.macInstanceTag == macInstanceTag,
                      response.macBuildID == macBuildID else {
                    return false
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
                return true
            } catch {
                guard !Task.isCancelled else { return false }
                phonePushKeyExchangeLog.error(
                    "key exchange failed attempt=\(attempt + 1, privacy: .public)"
                )
                guard attempt < 2 else { return false }
                try? await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        return false
    }
}
