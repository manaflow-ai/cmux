public import CMUXMobileCore
internal import CmuxMobileShellModel
internal import CmuxMobileTransport

/// Mac-viewer-only transport factory for `.tailscale` routes.
///
/// The shared `CmxNetworkByteTransportFactory` fails closed for tailscale:
/// a phone pairing from a scanned/pasted payload must never send the account
/// bearer over a tunnel Network.framework cannot prove is Tailscale's. The
/// Mac viewer's trust context differs — its routes come from the signed-in
/// account's own device registry — so this factory restores the
/// TCP-over-WireGuard lane, but only after verifying the host is actually
/// inside the tailnet address space (`100.64/10`, Tailscale's IPv6 ULA, or
/// `*.ts.net`); anything else fails exactly like the shared factory.
public struct HiveTailscaleByteTransportFactory: CmxByteTransportFactory {
    /// Creates the factory.
    public init() {}

    /// Route-only variant; same verification as the request variant.
    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try makeVerifiedTransport(route: route)
    }

    /// Builds a TCP transport for a verified tailnet route.
    /// - Throws: `CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable`
    ///   when the route is not a tailnet-classified tailscale host.
    public func makeTransport(for request: CmxByteTransportRequest) throws -> any CmxByteTransport {
        try makeVerifiedTransport(route: request.route)
    }

    private func makeVerifiedTransport(route: CmxAttachRoute) throws -> any CmxByteTransport {
        guard route.kind == .tailscale,
              case let .hostPort(host, port) = route.endpoint,
              MobileShellRouteAuthPolicy.routeAllowsStackAuth(
                  route,
                  trust: .loopbackAndTailscaleTunnel
              )
        else {
            throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
        }
        return try CmxNetworkByteTransport(host: host, port: port)
    }
}
