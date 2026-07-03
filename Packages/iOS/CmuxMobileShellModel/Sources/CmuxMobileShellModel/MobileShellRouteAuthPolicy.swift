public import CMUXMobileCore
import Foundation

/// Pure routing/trust policy that decides which attach routes may carry Stack auth
/// and how a manually typed host maps to a transport kind.
///
/// All members are pure functions of their inputs so the trust decisions (loopback
/// vs Tailscale vs LAN vs arbitrary host) can be exhaustively tested without a live
/// connection.
///
/// The Stack-bearer-token gate (``routeAllowsStackAuth(_:manualHostTrusted:)``)
/// is intentionally restricted to encrypted/loopback channels plus an explicit
/// per-host manual approval: the Tailscale tunnel (WireGuard-encrypted), iroh
/// peer connections (encrypted), loopback (never leaves the machine), and a
/// manual-host route only after the user accepts the plaintext-LAN warning.
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
    /// - Parameter host: The host to classify.
    /// - Returns: `.debugLoopback` for loopback hosts, `.tailscale` for
    ///   Tailscale IP/MagicDNS hosts, otherwise `.manualHost`.
    public func manualRouteKind(for host: String) -> CmxAttachTransportKind {
        let normalizedHost = (normalizedManualRouteHost(host) ?? host)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if isLoopbackHost(normalizedHost) {
            return .debugLoopback
        }
        if isTailscaleHost(normalizedHost) {
            return .tailscale
        }
        return .manualHost
    }

    /// Whether the given route is trusted enough to carry the Stack bearer token.
    ///
    /// The Stack `stack_access_token` is the owner's account credential, so it must
    /// only ever traverse an encrypted/loopback channel or an explicitly trusted
    /// manual-host route. This predicate gates every Stack-token-send site and
    /// returns `true` only for:
    ///
    /// - `.tailscale` to a Tailscale host (a `100.64.0.0/10` CGNAT address or a
    ///   `*.ts.net` MagicDNS host), which rides the WireGuard-encrypted tunnel.
    /// - `.iroh` to a peer, which is an encrypted QUIC connection.
    /// - `.debugLoopback` to a loopback host, which never leaves the machine.
    /// - `.manualHost` to a non-loopback host/port that has a persisted user approval.
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
    /// - Returns: `true` only for Tailscale-tunnel, iroh peer, loopback, and
    ///   explicitly approved manual-host routes.
    public func routeAllowsStackAuth(
        _ route: CmxAttachRoute,
        manualHostTrusted: Bool = false
    ) -> Bool {
        switch (route.kind, route.endpoint) {
        case (.debugLoopback, let .hostPort(host, _)):
            return isLoopbackHost(host)
        case (.tailscale, let .hostPort(host, _)):
            return isTailscaleHost(host)
        case (.manualHost, let .hostPort(host, _)):
            return manualHostTrusted && !isLoopbackHost(host)
        case (.iroh, .peer):
            return true
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

    /// Whether a manual host should warn the user that it is neither loopback nor Tailscale.
    /// - Parameter host: The manually typed host.
    /// - Returns: `true` when the host is valid but outside the loopback/Tailscale trust set.
    public func manualHostNeedsTrustWarning(_ host: String) -> Bool {
        guard normalizedManualNetworkHost(host) != nil else {
            return false
        }
        return manualRouteKind(for: host) == .manualHost
    }

    private func normalizedManualNetworkHost(_ host: String) -> String? {
        normalizedManualHost(host)?.lowercased()
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        loopbackHost.matches(host)
    }

    private func isTailscaleHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isTailscaleDNSHost(normalizedHost) || isTailscaleIPv4Host(normalizedHost)
    }

    private func isTailscaleIPv4Host(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else {
            return false
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part),
                  (0...255).contains(value) else {
                return nil
            }
            return value
        }
        guard octets.count == 4 else {
            return nil
        }
        return octets
    }

    private func isTailscaleDNSHost(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(".ts.net")
    }
}
