public import CMUXMobileCore
import Foundation

/// Pure routing/trust policy that decides which attach routes may carry Stack auth
/// and how a manually typed host maps to a transport kind.
///
/// All members are pure functions of their inputs so the trust decisions (loopback
/// vs Tailscale vs LAN vs arbitrary host) can be exhaustively tested without a live
/// connection.
///
/// Automatically discovered routes must be encrypted or loopback before they may
/// carry Stack auth. A host typed by the user is different: that is an explicit
/// trust decision for their own VPN, LAN, or private hostname, so it uses the
/// `.trustedNetwork` transport kind and may carry Stack auth.
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
    /// - Returns: `.debugLoopback` for loopback hosts, `.tailscale` for Tailscale
    ///   hosts, otherwise `.trustedNetwork`.
    public static func manualRouteKind(for host: String) -> CmxAttachTransportKind {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isLoopbackHost(normalizedHost) {
            return .debugLoopback
        }
        if isTailscaleHost(normalizedHost) {
            return .tailscale
        }
        return .trustedNetwork
    }

    /// Whether the given route is trusted enough to carry the Stack bearer token.
    ///
    /// The Stack `stack_access_token` is the owner's account credential, so it must
    /// only ever traverse an encrypted, loopback, or explicit user-trusted channel.
    /// This predicate gates every Stack-token-send site and returns `true` only for:
    ///
    /// - `.tailscale` to a Tailscale host (a `100.64.0.0/10` CGNAT address or a
    ///   `*.ts.net` MagicDNS host), which rides the WireGuard-encrypted tunnel.
    /// - `.trustedNetwork` to a user-entered host/port. The user decides that this
    ///   address is reachable through a trusted VPN, LAN, or device they control.
    /// - `.iroh` to a peer, which is an encrypted QUIC connection.
    /// - `.debugLoopback` to a loopback host, which never leaves the machine.
    ///
    /// Plain private-LAN (`192.168/16`, `10/8`, `172.16/12`, link-local) and
    /// `.local`/Bonjour hosts are still excluded when they are mislabeled as
    /// automatically discovered `.tailscale` routes; they must come through the
    /// manual `.trustedNetwork` path before carrying Stack auth.
    /// - Parameter route: The candidate attach route.
    /// - Returns: `true` for trusted routes that may carry Stack auth.
    public static func routeAllowsStackAuth(_ route: CmxAttachRoute) -> Bool {
        switch (route.kind, route.endpoint) {
        case (.debugLoopback, let .hostPort(host, _)):
            return isLoopbackHost(host)
        case (.tailscale, let .hostPort(host, _)):
            return isTailscaleHost(host)
        case (.trustedNetwork, .hostPort):
            return true
        case (.iroh, .peer):
            return true
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

    /// Whether a manual host should warn the user that it is neither loopback nor Tailscale.
    /// - Parameter host: The manually typed host.
    /// - Returns: `true` when the host is valid but outside the loopback/Tailscale trust set.
    public static func manualHostNeedsTrustWarning(_ host: String) -> Bool {
        guard let normalizedHost = normalizedManualNetworkHost(host) else {
            return false
        }
        return !isLoopbackHost(normalizedHost) && !isTailscaleHost(normalizedHost)
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

    private static func isTailscaleHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isTailscaleDNSHost(normalizedHost) || isTailscaleIPv4Host(normalizedHost)
    }

    private static func isTailscaleIPv4Host(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else {
            return false
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
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

    private static func isTailscaleDNSHost(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(".ts.net")
    }
}
