import Foundation

/// Single source of truth for "is this host loopback?" across the mobile
/// stack.
///
/// Pairing policy depends on this answer in two opposite directions, so it
/// must come from one place:
/// - Loopback is the *most* trusted channel for manual dev pairing (it never
///   leaves the machine, so it may carry the Stack bearer token).
/// - Loopback is *forbidden* in anything that arrives by QR or deep link: a
///   scanned code pointing at `127.0.0.1` would make the phone dial itself,
///   so the phone rejects it outright and the Mac never mints one.
///
/// The accepted spellings mirror the Mac host's connection-level check
/// (`MobileHostService.isLoopbackEndpoint`): `localhost` and `*.localhost`
/// names, `127.0.0.0/8`, IPv6 `::1`, and the IPv4-mapped `::ffff:127.0.0.0/8`.
public enum CmxLoopbackHost {
    /// Whether `host` names the local machine.
    /// - Parameter host: A bare host string (IPv4, IPv6 with or without
    ///   brackets, or a DNS name).
    public static func matches(_ host: String) -> Bool {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]"), normalized.count > 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            return true
        }
        if normalized == "::1" {
            return true
        }
        if normalized.hasPrefix("::ffff:") {
            return isIPv4Loopback(String(normalized.dropFirst("::ffff:".count)))
        }
        return isIPv4Loopback(normalized)
    }

    /// Whether `endpoint` dials a loopback host.
    /// - Parameter endpoint: The attach endpoint to classify.
    public static func matches(_ endpoint: CmxAttachEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else {
            return false
        }
        return matches(host)
    }

    /// Whether `route` is a loopback route: either declared as the
    /// `debugLoopback` transport kind or dialing a loopback host.
    /// - Parameter route: The attach route to classify.
    public static func matches(_ route: CmxAttachRoute) -> Bool {
        route.kind == .debugLoopback || matches(route.endpoint)
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
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
            return false
        }
        return octets[0] == 127
    }
}
