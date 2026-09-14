import Network

/// System routing may include Cloud private networks, never the public Internet.
public enum CloudVPNRoutePolicy {
    public static func permits(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
        if let ip = IPv4Address(String(parts[0])) {
            let bytes = Array(ip.rawValue)
            guard (0...32).contains(prefix) else { return false }
            return (bytes[0] == 10 && prefix >= 8)
                || (bytes[0] == 172 && (16...31).contains(bytes[1]) && prefix >= 12)
                || (bytes[0] == 192 && bytes[1] == 168 && prefix >= 16)
                || (bytes[0] == 100 && (64...127).contains(bytes[1]) && prefix >= 10)
        }
        if let ip = IPv6Address(String(parts[0])) {
            return (7...128).contains(prefix) && (ip.rawValue[0] & 0xfe) == 0xfc
        }
        return false
    }
}
