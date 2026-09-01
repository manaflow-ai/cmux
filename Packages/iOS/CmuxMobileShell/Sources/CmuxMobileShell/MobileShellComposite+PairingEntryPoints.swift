import CMUXMobileCore
import CmuxMobilePairedMac
public import CmuxMobileShellModel

@MainActor
extension MobileShellComposite {
    /// Connect using the current pairing input, accepting either a code or pairing URL.
    @discardableResult
    public func connectPairingInput() async -> MobilePairingURLConnectionResult {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { return .failed }
        if CmxPairingURLScheme(urlString: trimmedCode) != nil {
            // Reading a pairing code in this UI is the authorization event for
            // compatibility Tailscale routes.
            return await connectPairingURLResult(trimmedCode, userEnteredPairingCode: true)
        }
        connectPreviewHost()
        return .connected
    }

    /// Connect to a manually-entered Mac host and optionally associate the
    /// resulting session with an existing paired-Mac device id.
    @discardableResult
    public func connectManualHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String? = nil
    ) async -> MobilePairingURLConnectionResult {
        await connectManualHost(
            name: name,
            host: host,
            port: port,
            pairedMacDeviceID: pairedMacDeviceID,
            recordsPairingAttempt: true
        )
    }

    /// The strict Tailscale allowlist used during reconnect. Migration grants
    /// retain numeric peer proof; user grants also cover explicit DNS/LAN hosts.
    struct TailscaleRouteRequirement {
        let macDeviceID: String
        let grantRoutes: [CmxAttachRoute]
        let userGrantRoutes: [CmxAttachRoute]

        init(
            macDeviceID: String,
            grantRoutes: [CmxAttachRoute],
            userGrantRoutes: [CmxAttachRoute] = []
        ) {
            self.macDeviceID = macDeviceID
            self.grantRoutes = grantRoutes
            self.userGrantRoutes = userGrantRoutes
        }
    }

    func tailscaleRouteRequirement(for mac: MobilePairedMac) -> TailscaleRouteRequirement? {
        guard connectionMethod(for: mac) == .tailscale else { return nil }
        return TailscaleRouteRequirement(
            macDeviceID: mac.macDeviceID,
            grantRoutes: mac.legacyTailscaleRoutes ?? [],
            userGrantRoutes: mac.userAuthorizedTailscaleRoutes ?? []
        )
    }
}
