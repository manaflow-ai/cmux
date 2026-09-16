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
        phonePushKeyExchangeRetryTask?.cancel()
        phonePushKeyExchangeRetryTask = nil
        let exchanged = await performPhonePushKeyExchange(
            client: client,
            accountID: accountID,
            macDeviceID: macDeviceID,
            macInstanceTag: macInstanceTag,
            macBuildID: macBuildID
        )
        guard !exchanged, !Task.isCancelled else { return }
        phonePushKeyExchangeRetryTask = Task { @MainActor [weak self, client] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self else { return }
                let exchanged = await self.performPhonePushKeyExchange(
                    client: client,
                    accountID: accountID,
                    macDeviceID: macDeviceID,
                    macInstanceTag: macInstanceTag,
                    macBuildID: macBuildID
                )
                if exchanged { return }
            }
        }
    }

    private func performPhonePushKeyExchange(
        client: MobileCoreRPCClient,
        accountID: String,
        macDeviceID: String,
        macInstanceTag: String,
        macBuildID: String
        ) async -> Bool {
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return false }
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
                return true
            } catch {
                phonePushKeyExchangeLog.error(
                    "key exchange failed attempt=\(attempt + 1, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                guard attempt < 2 else { return false }
                try? await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        return false
    }
}
