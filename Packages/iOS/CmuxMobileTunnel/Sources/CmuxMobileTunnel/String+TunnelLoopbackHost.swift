import Network

/// Destinations that mean "the exit machine itself": `localhost`,
/// `*.localhost` (RFC 6761), `127.0.0.0/8`, `::1`, and the unspecified
/// addresses browsers treat as local.
extension String {
    /// Whether this destination host means the exit machine itself.
    public var isTunnelLoopbackHost: Bool {
        var host = lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "0.0.0.0" || host == "::" { return true }
        if let v6 = IPv6Address(host) {
            if v6 == .loopback { return true }
            if let mapped = v6.asIPv4 { return mapped.isLoopback }
            return false
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
