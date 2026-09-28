import Network

/// Which destinations the system VPN may route: Cloud's private networks,
/// never the public Internet.
///
/// Checked twice, by the app before it saves a configuration and by the
/// packet tunnel before it starts one, so neither a bad enrollment nor an
/// edited preference can turn the VPN into a full tunnel. The extension
/// compiles this file directly, so it depends on nothing else in the package.
public struct CloudVPNRoutePolicy: Sendable {
    public init() {}

    /// Whether `cidr` lies entirely inside a private range: RFC 1918,
    /// carrier-grade NAT (100.64.0.0/10) or IPv6 unique local (fc00::/7).
    public func permits(_ cidr: String) -> Bool {
        let parts = cidr.trimmingCharacters(in: .whitespaces)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
        if let ip = IPv4Address(String(parts[0])) {
            guard (0...32).contains(prefix) else { return false }
            let bytes = Array(ip.rawValue)
            return (bytes[0] == 10 && prefix >= 8)
                || (bytes[0] == 172 && (16...31).contains(bytes[1]) && prefix >= 12)
                || (bytes[0] == 192 && bytes[1] == 168 && prefix >= 16)
                || (bytes[0] == 100 && (64...127).contains(bytes[1]) && prefix >= 10)
        }
        if let ip = IPv6Address(String(parts[0])) {
            return (7...128).contains(prefix) && (ip.rawValue[0] & 0xFE) == 0xFC
        }
        return false
    }
}
