public import CMUXMobileCore
import Foundation

/// Pure routing/trust policy that decides which attach routes may carry Stack auth
/// and how a manually typed host maps to a transport kind.
///
/// All members are pure functions of their inputs so the trust decisions (loopback
/// vs Tailscale vs LAN vs arbitrary host) can be exhaustively tested without a live
/// connection. The host classification is intentionally conservative: only loopback,
/// Tailscale, private-LAN, and `.local`/`.ts.net` DNS hosts are treated as trusted.
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

    /// Whether the given route is trusted enough to carry Stack auth credentials.
    /// - Parameter route: The candidate attach route.
    /// - Returns: `true` only for loopback, Tailscale/LAN/local-DNS, and iroh peer routes.
    public static func routeAllowsStackAuth(_ route: CmxAttachRoute) -> Bool {
        switch (route.kind, route.endpoint) {
        case (.debugLoopback, let .hostPort(host, _)):
            return isLoopbackHost(host)
        case (.tailscale, let .hostPort(host, _)):
            return isTailscaleHost(host) || isPrivateLANHost(host) || isLocalDNSHost(host)
        case (.iroh, .peer):
            return true
        default:
            return false
        }
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

    private static func isPrivateLANHost(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return false
        }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254)
    }

    private static func isLocalDNSHost(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(".local")
    }
}
