import Foundation

public extension CmxIrohNetworkProfileKey {
    /// The strongest Tailscale profile iOS can prove without a provider API.
    ///
    /// Apple exposes the active packet tunnel and its assigned addresses, but
    /// not Tailscale's tailnet identifier. This profile therefore means "a
    /// Tailscale tunnel is active on this device." It is routing metadata only;
    /// the Iroh EndpointID remains the peer-authentication authority.
    static var activeTailscaleTunnel: CmxIrohNetworkProfileKey? {
        try? CmxIrohNetworkProfileKey(
            source: .tailscale,
            profileID: "42e59eea27473bde00430ca3d4a0f34a372713f0b90d46ee1ab2802c6d668979"
        )
    }
}

public extension CmxAttachRoute {
    /// Adds short-lived Tailscale addresses to every existing Iroh route.
    ///
    /// Private paths never contribute identity or authorization. They are
    /// attached only to an existing Iroh EndpointID and remain fallback-only,
    /// so a wrong or stale address can only fail Iroh's authenticated handshake.
    /// Numeric Tailscale validation rejects LAN, public, MagicDNS, service, and
    /// generic host routes. The original raw routes remain in the returned set
    /// for rolling compatibility, but callers continue pinning connection
    /// attempts to Iroh whenever an Iroh route exists.
    static func addingIrohPrivatePaths(
        to routes: [CmxAttachRoute],
        observedAt: Date
    ) -> [CmxAttachRoute] {
        let tailscaleHints = routes.compactMap {
            $0.irohTailscalePathHint(observedAt: observedAt)
        }
        guard !tailscaleHints.isEmpty else { return routes }

        return routes.map { route in
            guard route.kind == .iroh,
                  case let .peer(identity, pathHints) = route.endpoint else {
                return route
            }
            var hints = pathHints
            for hint in tailscaleHints {
                hints.removeAll { existing in
                    existing.kind == hint.kind
                        && existing.value == hint.value
                        && existing.source == hint.source
                        && existing.networkProfile == hint.networkProfile
                }
                guard hints.count < CmxAttachEndpoint.maximumIrohPathHintCount else {
                    continue
                }
                hints.append(hint)
            }
            return (try? CmxAttachRoute(
                id: route.id,
                kind: route.kind,
                endpoint: .peer(identity: identity, pathHints: hints),
                priority: route.priority
            )) ?? route
        }
    }

    /// Creates one fallback-only Iroh hint from a canonical Tailscale peer.
    func irohTailscalePathHint(observedAt: Date) -> CmxIrohPathHint? {
        guard kind == .tailscale,
              case let .hostPort(host, port) = endpoint,
              let address = CmxTailscalePeerAddress(host),
              let profile = CmxIrohNetworkProfileKey.activeTailscaleTunnel else {
            return nil
        }
        let socketAddress: String
        switch address.family {
        case .ipv4:
            socketAddress = "\(address.value):\(port)"
        case .ipv6:
            socketAddress = "[\(address.value)]:\(port)"
        }
        return try? CmxIrohPathHint(
            kind: .directAddress,
            value: socketAddress,
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(
                CmxIrohPathHint.maximumPrivateHintTTL
            ),
            networkProfile: profile
        )
    }
}
