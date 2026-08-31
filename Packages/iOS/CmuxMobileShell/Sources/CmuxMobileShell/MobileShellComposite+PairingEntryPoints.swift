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

    /// The user-entered pairing-code authorization covering `route`, if any.
    /// It is anchored on the exact destination; a claimed device identity
    /// carries no authority.
    static func userTailscalePairingAuthorization(
        for route: CmxAttachRoute,
        authorizations: [CmxUserTailscalePairingAuthorization]
    ) -> CmxUserTailscalePairingAuthorization? {
        guard route.kind == .tailscale,
              case let .hostPort(host, port) = route.endpoint else { return nil }
        return authorizations.first { $0.authorizes(host: host, port: port) }
    }

    static func explicitlyAuthorizedTailscaleRoutes(
        from routes: [CmxAttachRoute],
        authorizations: [CmxUserTailscalePairingAuthorization]
    ) -> [CmxAttachRoute]? {
        let matches = routes.filter {
            userTailscalePairingAuthorization(for: $0, authorizations: authorizations) != nil
        }
        return matches.isEmpty ? nil : matches
    }

    nonisolated static func userTailscalePairingAuthorization(
        for route: CmxAttachRoute,
        persistedRoutes: [CmxAttachRoute]
    ) -> CmxUserTailscalePairingAuthorization? {
        guard route.kind == .tailscale,
              case let .hostPort(host, port) = route.endpoint else { return nil }
        for stored in persistedRoutes where stored.kind == .tailscale {
            guard case let .hostPort(storedHost, storedPort) = stored.endpoint,
                  let authorization = try? CmxUserTailscalePairingAuthorization(
                      host: storedHost, port: storedPort
                  ) else { continue }
            if authorization.authorizes(host: host, port: port) { return authorization }
        }
        return nil
    }

    nonisolated static func userTailscalePairingAuthorizations(
        from routes: [CmxAttachRoute]
    ) -> [CmxUserTailscalePairingAuthorization] {
        routes.compactMap { route in
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else { return nil }
            return try? CmxUserTailscalePairingAuthorization(host: host, port: port)
        }
    }

    static func storedMacTicket(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "stored-workspace",
            terminalID: nil,
            macDeviceID: pairedMacDeviceID,
            macDisplayName: name,
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: routes
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
        guard connectionMethod(for: mac) == .tailscale,
              !mac.routes.contains(where: { $0.kind == .iroh }) else { return nil }
        return TailscaleRouteRequirement(
            macDeviceID: mac.macDeviceID,
            grantRoutes: mac.legacyTailscaleRoutes ?? [],
            userGrantRoutes: mac.userAuthorizedTailscaleRoutes ?? []
        )
    }
}
