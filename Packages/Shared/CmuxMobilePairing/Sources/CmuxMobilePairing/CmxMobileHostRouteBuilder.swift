public import CMUXMobileCore
import Darwin

/// Builds the authenticated host route snapshot advertised to mobile clients.
///
/// This value-only builder keeps route classification and deterministic
/// priority assignment out of the executable host service. Interface and DNS
/// discovery remain injectable at the app boundary; callers provide the
/// resulting host strings here.
public struct CmxMobileHostRouteBuilder: Sendable {
    /// Creates a stateless route builder.
    public init() {}

    /// Creates route values from already-discovered LAN and Tailscale hosts.
    ///
    /// LAN priorities use the odd grid `5, 15, 25, ...`; Tailscale uses
    /// `10, 20, 30, ...`, so cross-class ordering never depends on an ID tie.
    /// - Parameters:
    ///   - port: The listener port shared by each host route.
    ///   - tailscaleHosts: Numeric Tailscale addresses (DNS names are ignored).
    ///   - lanHosts: Numeric local-network addresses.
    ///   - includeDebugLoopback: Whether to include the DEBUG-only loopback route.
    /// - Returns: Deterministically ordered route values.
    public func routes(
        port: Int,
        tailscaleHosts: [String],
        lanHosts: [String],
        includeDebugLoopback: Bool = false
    ) -> [CmxAttachRoute] {
        var resolved: [CmxAttachRoute] = []
        if includeDebugLoopback,
           let route = try? CmxAttachRoute(
               id: CmxAttachTransportKind.debugLoopback.rawValue,
               kind: .debugLoopback,
               endpoint: .hostPort(host: "127.0.0.1", port: port),
               priority: 0
           ) {
            resolved.append(route)
        }

        let lan = Self.deduplicatedHosts(lanHosts).filter {
            Self.isLANPeerAddress($0) && !Self.isTailscalePeerAddress($0)
        }
        for (index, host) in lan.enumerated() {
            let id = index == 0
                ? CmxAttachTransportKind.lan.rawValue
                : "\(CmxAttachTransportKind.lan.rawValue)_\(index + 1)"
            if let route = try? CmxAttachRoute(
                id: id,
                kind: .lan,
                endpoint: .hostPort(host: host, port: port),
                priority: 5 + index * 10
            ) {
                resolved.append(route)
            }
        }

        let tailscale = Self.deduplicatedHosts(tailscaleHosts).filter {
            Self.isTailscalePeerAddress($0)
        }
        for (index, host) in tailscale.enumerated() {
            let id = index == 0
                ? CmxAttachTransportKind.tailscale.rawValue
                : "\(CmxAttachTransportKind.tailscale.rawValue)_\(index + 1)"
            if let route = try? CmxAttachRoute(
                id: id,
                kind: .tailscale,
                endpoint: .hostPort(host: host, port: port),
                priority: 10 + index * 10
            ) {
                resolved.append(route)
            }
        }
        return resolved
    }

    /// Removes empty and case-insensitive duplicate host spellings.
    public static func deduplicatedHosts(_ hosts: [String]) -> [String] {
        var seen: Set<String> = []
        return hosts.filter { host in
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return false
            }
            return true
        }
    }

    /// Returns whether a host is a private/local-network IP literal.
    public static func isLANPeerAddress(_ host: String) -> Bool {
        let normalized = host.split(
            separator: "%",
            maxSplits: 1,
            omittingEmptySubsequences: true
        ).first.map(String.init) ?? host
        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            guard octets.allSatisfy({ (0 ... 255).contains($0) }) else { return false }
            if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) {
                return true
            }
            if octets[0] == 172 && (16 ... 31).contains(octets[1]) {
                return true
            }
            return octets[0] == 169 && octets[1] == 254
        }

        var address = in6_addr()
        guard normalized.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        // IPv6 link-local addresses need an interface scope and are not safe to
        // copy from the Mac to an iPhone. Only ULA addresses are advertised.
        return bytes.first.map { $0 & 0xfe == 0xfc } ?? false
    }

    /// Returns whether a host is a Tailscale CGNAT or stable ULA address.
    public static func isTailscalePeerAddress(_ host: String) -> Bool {
        isTailscaleCGNAT(host) || isTailscaleIPv6ULA(host)
    }

    private static func isTailscaleCGNAT(_ ipAddress: String) -> Bool {
        let octets = ipAddress.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4,
              octets[0] == 100,
              (64 ... 127).contains(octets[1]) else {
            return false
        }
        if octets[1] == 100, octets[2] == 0 || octets[2] == 100 {
            return false
        }
        if octets[1] == 115, octets[2] == 92 || octets[2] == 93 {
            return false
        }
        return true
    }

    private static func isTailscaleIPv6ULA(_ ipAddress: String) -> Bool {
        var address = in6_addr()
        guard ipAddress.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        return bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    }
}
