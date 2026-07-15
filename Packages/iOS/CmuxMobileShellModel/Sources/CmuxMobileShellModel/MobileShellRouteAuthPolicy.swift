public import CMUXMobileCore
import Foundation

/// Pure routing/trust policy that decides which attach routes may carry Stack auth
/// and how a manually typed host maps to a conservative transport kind.
///
/// All members are pure functions of their inputs so the trust decisions (loopback
/// vs Tailscale vs LAN vs arbitrary host) can be exhaustively tested without a live
/// connection.
///
/// The Stack-bearer-token gate (``routeAllowsStackAuth(_:manualHostTrusted:)``)
/// is intentionally restricted to loopback plus an explicit per-host manual
/// approval. Iroh sessions authenticate RPC out of band and never carry a Stack
/// bearer token; a generic packet-tunnel interface does not prove Tailscale
/// provenance, so `.tailscale` host routes also cannot carry that credential.
/// Plain private-LAN and `.local`/Bonjour hosts remain excluded by default even
/// though they may still be reachable as attach routes.
public struct MobileShellRouteAuthPolicy: Sendable {
    private let loopbackHost: CmxLoopbackHost

    /// Creates a route-auth policy with an injectable loopback host matcher.
    /// - Parameter loopbackHost: Matcher used to recognize loopback aliases.
    public init(loopbackHost: CmxLoopbackHost = CmxLoopbackHost()) {
        self.loopbackHost = loopbackHost
    }

    /// Normalizes a raw, user-entered host string, stripping IPv6 brackets and
    /// rejecting anything that contains scheme/path/whitespace characters.
    /// - Parameter rawHost: The raw host string typed by the user.
    /// - Returns: The normalized bare host, or `nil` when it is not a valid host.
    public func normalizedManualHost(_ rawHost: String) -> String? {
        CmxManualHost(rawHost)?.rawValue
    }

    /// Normalizes an already-stored attach-route endpoint host.
    ///
    /// Unlike ``normalizedManualHost(_:)``, this accepts bare IPv6 because route
    /// endpoints store IPv6 hosts without brackets.
    public func normalizedManualRouteHost(_ rawHost: String) -> String? {
        CmxManualHost(routeHost: rawHost)?.rawValue
    }

    /// Maps a manually typed host to the transport kind that should be used.
    /// - Parameters:
    ///   - host: The host to classify.
    ///   - allowsDebugLoopback: Whether loopback aliases should become
    ///     `.debugLoopback`. Keep this `false` for physical-device manual entry:
    ///     loopback dials the phone itself there, not the Mac.
    /// - Returns: `.debugLoopback` for allowed loopback hosts, `.manualHost`
    ///   otherwise, or `nil` for an invalid host. Host text alone never proves
    ///   that a raw TCP connection traverses Tailscale; only a structured route
    ///   may carry that provenance.
    public func manualRouteKind(
        for host: String,
        allowsDebugLoopback: Bool = true
    ) -> CmxAttachTransportKind? {
        guard let normalizedHost = normalizedManualRouteHost(host)?.lowercased() else {
            return nil
        }
        if allowsDebugLoopback, isLoopbackHost(normalizedHost) {
            return .debugLoopback
        }
        return .manualHost
    }

    /// Whether the given route is trusted enough to carry the Stack bearer token.
    ///
    /// The Stack `stack_access_token` is the owner's account credential, so it must
    /// only ever traverse loopback or an explicitly approved manual-host route.
    /// Iroh authorizes RPC through its admitted session, while raw `.tailscale`
    /// text lacks structural transport proof and therefore remains fail-closed.
    ///
    /// Plain private-LAN (`192.168/16`, `10/8`, `172.16/12`, link-local) and
    /// `.local`/Bonjour hosts are deliberately **excluded**: they are dialed over
    /// unencrypted TCP (``CmxNetworkByteTransport`` uses `NWParameters(tls: nil)`),
    /// so sending the bearer token to such a host would disclose it in plaintext on
    /// the local network before the Mac proves it is the same-account host.
    /// - Parameters:
    ///   - route: The candidate attach route.
    ///   - manualHostTrusted: Whether this exact `.manualHost` route has an
    ///     explicit persisted trust approval.
    /// - Returns: `true` only for loopback and explicitly approved manual-host
    ///   routes.
    public func routeAllowsStackAuth(
        _ route: CmxAttachRoute,
        manualHostTrusted: Bool = false
    ) -> Bool {
        switch (route.kind, route.endpoint) {
        case (.debugLoopback, let .hostPort(host, _)):
            return isLoopbackHost(host)
        case (.manualHost, let .hostPort(host, _)):
            return manualHostTrusted && !isLoopbackHost(host)
        case (.tailscale, .hostPort), (.iroh, .peer):
            return false
        default:
            return false
        }
    }

    /// Whether a route is an explicit manual-host route that needs approval.
    /// - Parameter route: The candidate attach route.
    /// - Returns: `true` only for `.manualHost` host/port routes.
    public func routeRequiresManualHostTrust(_ route: CmxAttachRoute) -> Bool {
        guard route.kind == .manualHost,
              case let .hostPort(host, _) = route.endpoint else {
            return false
        }
        return !isLoopbackHost(host)
    }

    /// Whether a decoded pairing/attach ticket must be rejected because its
    /// routes dial the device itself.
    ///
    /// On a physical phone a loopback route can never name a legitimate Mac:
    /// dialing it reaches whatever process is listening on the phone's own
    /// localhost, and since loopback is in the Stack-auth-trusted set
    /// (``routeAllowsStackAuth(_:)``) the account bearer token would be
    /// handed to that process. The v2 pairing-QR grammar rejects loopback in
    /// the decoder; this policy closes the same hole for the legacy payload
    /// grammars, which must keep decoding loopback for the simulator flow
    /// (where 127.0.0.1 IS the host Mac and dev auto-pair depends on it).
    /// - Parameters:
    ///   - routes: The decoded ticket's routes.
    ///   - isPhysicalDevice: `true` on a physical iPhone/iPad, `false` in the
    ///     simulator and on other platforms.
    /// - Returns: `true` when the ticket must fail with the loopback-rejected
    ///   error instead of connecting.
    public func ticketRejectsLoopbackRoutes(
        _ routes: [CmxAttachRoute],
        isPhysicalDevice: Bool
    ) -> Bool {
        isPhysicalDevice && routes.contains(where: routeIsLoopback)
    }

    /// Whether the given route may carry Stack auth when reached via an implicit
    /// pair-link (no explicit attach token), restricted to loopback only.
    /// - Parameter route: The candidate attach route.
    /// - Returns: `true` only for loopback host/port routes.
    public func routeAllowsImplicitPairLinkStackAuth(_ route: CmxAttachRoute) -> Bool {
        switch (route.kind, route.endpoint) {
        case (.debugLoopback, let .hostPort(host, _)):
            return isLoopbackHost(host)
        default:
            return false
        }
    }

    /// Whether the route dials a loopback endpoint, which stays reachable with
    /// no external network path (simulator/dev pairing to `127.0.0.1`), so an
    /// offline reachability preflight must not block an attempt that can still
    /// dial it.
    /// - Parameter route: The candidate attach route.
    /// - Returns: `true` when the route's host/port endpoint is a loopback host.
    public func routeIsLoopback(_ route: CmxAttachRoute) -> Bool {
        guard case let .hostPort(host, _) = route.endpoint else {
            return false
        }
        return isLoopbackHost(host)
    }

    /// Whether a manually entered host should show the plaintext-route warning.
    /// - Parameters:
    ///   - host: The manually typed host.
    ///   - allowsDebugLoopback: Whether loopback aliases are trusted debug hosts
    ///     for this caller.
    /// - Returns: `true` for every valid host except an allowed debug loopback.
    public func manualHostNeedsTrustWarning(
        _ host: String,
        allowsDebugLoopback: Bool = true
    ) -> Bool {
        guard normalizedManualNetworkHost(host) != nil else {
            return false
        }
        return manualRouteKind(for: host, allowsDebugLoopback: allowsDebugLoopback) == .manualHost
    }

    private func normalizedManualNetworkHost(_ host: String) -> String? {
        normalizedManualHost(host)?.lowercased()
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        loopbackHost.matches(host)
    }

}
