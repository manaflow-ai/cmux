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
        let isPrimaryClient = client === remoteClient
        if isPrimaryClient {
            phonePushKeyExchangeStatus = status
        }
        guard status.capabilities.contains(Self.phonePushKeyExchangeCapability) else {
            if isPrimaryClient { phonePushKeyExchangeFailed = false }
            diagnosticLog?.recordAppEvent(.pushKeyExchangeUnsupported, failure: .unsupportedRoute)
            return
        }
        guard phonePushKeyExchangeHooks != nil,
              let accountID = identityProvider?.currentUserID,
              !accountID.isEmpty,
              let macDeviceID = status.macDeviceID,
              let macInstanceTag = status.macInstanceTag,
              let macClientNamespace = status.macClientNamespace else {
            let missing = [
                phonePushKeyExchangeHooks == nil ? "hooks" : nil,
                (identityProvider?.currentUserID ?? "").isEmpty ? "account" : nil,
                status.macDeviceID == nil ? "mac_device" : nil,
                status.macInstanceTag == nil ? "mac_instance_tag" : nil,
                status.macClientNamespace == nil ? "mac_namespace" : nil,
            ].compactMap { $0 }
            phonePushKeyExchangeLog.error(
                "key exchange skipped, missing: \(missing.joined(separator: ","), privacy: .public)"
            )
            if isPrimaryClient { phonePushKeyExchangeFailed = true }
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
                    macClientNamespace: macClientNamespace
                )
                guard !Task.isCancelled, self.identityProvider?.currentUserID == accountID else { return }
                if exchanged {
                    if self.remoteClient === client {
                        self.phonePushKeyExchangeFailed = false
                    }
                    self.diagnosticLog?.recordAppEvent(.pushKeyExchangeSucceeded)
                    return
                }
                guard retry < 2 else { break }
                try? await Task.sleep(for: .seconds(1 << retry))
            }
            guard !Task.isCancelled, let self else { return }
            guard self.remoteClient === client else { return }
            self.phonePushKeyExchangeFailed = true
            self.diagnosticLog?.recordAppEvent(.pushKeyExchangeFailed, failure: .secureChannelFailed)
            phonePushKeyExchangeLog.error("key exchange failed; reconnect or reopen the app to retry secure push setup")
        }
    }

    private func performPhonePushKeyExchange(
        client: MobileCoreRPCClient,
        accountID: String,
        macDeviceID: String,
        macInstanceTag: String,
        macClientNamespace: String
    ) async -> Bool {
        guard let hooks = phonePushKeyExchangeHooks else { return false }
        guard !Task.isCancelled, identityProvider?.currentUserID == accountID else { return false }
        do {
            let exchange = try await client.exchangePhonePushKey(
                hooks: hooks,
                clientID: clientID
            )
            let response = exchange.response
            guard !Task.isCancelled,
                  identityProvider?.currentUserID == accountID else { return false }
            // Name the mismatched field (never its value) so a rejected reply
            // is diagnosable from device logs.
            let mismatches = [
                response.accountID == accountID ? nil : "account",
                response.macDeviceID == macDeviceID ? nil : "mac_device",
                response.macInstanceTag == macInstanceTag ? nil : "mac_instance_tag",
                response.matchesMacClientNamespace(macClientNamespace) ? nil : "mac_namespace",
            ].compactMap { $0 }
            guard mismatches.isEmpty else {
                phonePushKeyExchangeLog.error(
                    "key exchange reply rejected: \(mismatches.joined(separator: ","), privacy: .public)"
                )
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
                "key exchange attempt failed: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)"
            )
            return false
        }
    }
}
