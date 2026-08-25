public import CMUXMobileCore
internal import CmuxMobileShellModel
internal import CmuxMobileTransport

/// Mac-viewer-only transport factory for `.tailscale` routes.
///
/// The shared `CmxNetworkByteTransportFactory` fails closed for tailscale:
/// a phone pairing from a scanned/pasted payload must never send the account
/// bearer over a tunnel Network.framework cannot prove is Tailscale's. The
/// Legacy Tailscale TCP remains fail-closed: a numeric tailnet address is not
/// a cryptographic peer-admission proof, so a Stack bearer is accepted only
/// for a future `.transportAdmission` handshake. DEBUG loopback uses the
/// shared local factory instead.
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
        guard request.authorizationMode == .transportAdmission else {
            throw CmxNetworkByteTransportError.unsupportedAuthorizationMode(
                request.authorizationMode
            )
        }
        return try makeVerifiedTransport(route: request.route)
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
