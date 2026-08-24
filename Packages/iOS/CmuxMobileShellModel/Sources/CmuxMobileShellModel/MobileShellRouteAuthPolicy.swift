public import CMUXMobileCore
import Foundation

/// Pure routing/trust policy that decides which attach routes may carry Stack auth
/// and how a manually typed host maps to a transport kind.
///
/// All members are pure functions of their inputs so the trust decisions (loopback
/// vs Tailscale vs LAN vs arbitrary host) can be exhaustively tested without a live
/// connection.
///
/// The Stack-bearer-token gate (``routeAllowsStackAuth(_:)``) is intentionally
/// restricted to **loopback**, which never leaves the machine. iOS cannot prove
/// that a generic packet-tunnel interface belongs to Tailscale's authenticated
/// control plane, so a Tailscale-address heuristic is insufficient for sending
/// an account credential over plaintext TCP. Iroh sessions authenticate RPC out
/// of band and never carry a Stack bearer token. Plain
/// private-LAN and `.local`/Bonjour hosts are dialed
/// over unencrypted TCP (``CmxNetworkByteTransport`` uses `NWParameters(tls: nil)`),
/// so they are excluded from the Stack-auth-allowed set even though they may still
/// be reachable as attach routes.
public struct MobileShellRouteAuthPolicy {
    private init() {}

    /// Normalizes a raw, user-entered host string, stripping IPv6 brackets and
    /// rejecting anything that contains scheme/path/whitespace characters.
    /// - Parameter rawHost: The raw host string typed by the user.
    /// - Returns: The normalized bare host, or `nil` when it is not a valid host.
    public static func normalizedManualHost(_ rawHost: String) -> String? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let host: String
        if trimmed.hasPrefix("[") || trimmed.hasSuffix("]") {
            guard trimmed.hasPrefix("["),
                  trimmed.hasSuffix("]"),
                  trimmed.count > 2 else {
                return nil
            }
            host = String(trimmed.dropFirst().dropLast())
        } else {
            host = trimmed
        }

        guard !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@")) == nil,
              host.range(of: "://") == nil else {
            return nil
        }
        return host
    }

    /// Maps a manually typed host to the transport kind that should be used.
    /// - Parameter host: The host to classify.
    /// - Returns: `.debugLoopback` for loopback hosts, otherwise `.tailscale`.
    public static func manualRouteKind(for host: String) -> CmxAttachTransportKind {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isLoopbackHost(normalizedHost) {
            return .debugLoopback
        }
        return .tailscale
    }

    /// Whether the given route is trusted enough to carry the Stack bearer token.
    ///
    /// The Stack `stack_access_token` is the owner's account credential, so it must
    /// only ever traverse loopback. This predicate gates every Stack-token-send
    /// site and returns `true` only for `.debugLoopback` to a loopback host.
    ///
    /// Plain private-LAN (`192.168/16`, `10/8`, `172.16/12`, link-local) and
    /// `.local`/Bonjour hosts are deliberately **excluded**: they are dialed over
    /// unencrypted TCP (``CmxNetworkByteTransport`` uses `NWParameters(tls: nil)`),
    /// so sending the bearer token to such a host would disclose it in plaintext on
    /// the local network before the Mac proves it is the same-account host.
    /// Iroh routes always return `false`. Their authenticated session context
    /// authorizes RPC without disclosing the account bearer token to the peer.
    /// - Parameter route: The candidate attach route.
    /// - Returns: `true` only for a loopback route.
    public static func routeAllowsStackAuth(_ route: CmxAttachRoute) -> Bool {
        switch (route.kind, route.endpoint) {
        case (.debugLoopback, let .hostPort(host, _)):
            return isLoopbackHost(host)
        case (.tailscale, .hostPort), (.iroh, .peer):
            return false
        default:
            return false
        }
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
    public static func ticketRejectsLoopbackRoutes(
        _ routes: [CmxAttachRoute],
        isPhysicalDevice: Bool
    ) -> Bool {
        isPhysicalDevice && routes.contains(where: CmxLoopbackHost().matches)
    }

    /// Whether the given route may carry Stack auth when reached via an implicit
    /// pair-link (no explicit attach token), restricted to loopback only.
    /// - Parameter route: The candidate attach route.
    /// - Returns: `true` only for loopback host/port routes.
    public static func routeAllowsImplicitPairLinkStackAuth(_ route: CmxAttachRoute) -> Bool {
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
    public static func routeIsLoopback(_ route: CmxAttachRoute) -> Bool {
        guard case let .hostPort(host, _) = route.endpoint else {
            return false
        }
        return isLoopbackHost(host)
    }

    /// Whether a manual host should warn that it cannot carry account credentials.
    /// - Parameter host: The manually typed host.
    /// - Returns: `true` for every valid host outside loopback.
    public static func manualHostNeedsTrustWarning(_ host: String) -> Bool {
        guard let normalizedHost = normalizedManualNetworkHost(host) else {
            return false
        }
        return !isLoopbackHost(normalizedHost)
    }

    private static func normalizedManualNetworkHost(_ host: String) -> String? {
        normalizedManualHost(host)?.lowercased()
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedHost == "localhost" ||
            normalizedHost == "::1" ||
            isIPv4LoopbackHost(normalizedHost)
    }

    private static func isIPv4LoopbackHost(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else {
            return false
        }
        return octets[0] == 127
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
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

}
