/// Machine addresses on the owner's private Cloud network.
public struct CmxCloudNetworkAddresses: Codable, Equatable, Sendable {
    /// Private IPv4 address, when supplied by the provider.
    public let ipv4: String?
    /// Private IPv6 address, when supplied by the provider.
    public let ipv6: String?

    /// Creates private network metadata, preserving absent address families.
    /// - Parameters:
    ///   - ipv4: Optional IPv4 address.
    ///   - ipv6: Optional IPv6 address.
    public init(ipv4: String? = nil, ipv6: String? = nil) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}
