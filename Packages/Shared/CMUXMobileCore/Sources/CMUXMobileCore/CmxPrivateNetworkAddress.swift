import Foundation

/// A canonical private-network address discovered on one Mac interface.
///
/// The address is a coordinate only. Callers must combine it with the
/// broker-authenticated Mac's current Iroh UDP port and EndpointID.
public struct CmxPrivateNetworkAddress: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The broad role of the interface that owns a discovered address.
    public enum Kind: String, Codable, Sendable {
        /// A VPN or tunnel interface such as WireGuard, IPsec, or `utun`.
        case vpnTunnel = "vpn_tunnel"
        /// A local physical or bridged network interface.
        case localNetwork = "local_network"
        /// An unrecognized interface carrying a private-shaped address.
        case other
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case family
        case interfaceName = "interface"
        case kind
    }

    /// Canonical numeric IPv4 or IPv6 text without brackets, a zone, or a port.
    public let address: String
    /// The numeric address family.
    public let family: CmxIrohCustomPrivateAddress.Family
    /// The interface name reported by the operating system.
    public let interfaceName: String
    /// The classified role of ``interfaceName``.
    public let kind: Kind

    /// A stable identifier scoped to the interface and canonical address.
    public var id: String { "\(interfaceName)/\(address)" }

    /// Creates a validated discovered-address value.
    ///
    /// - Parameters:
    ///   - address: A numeric IPv4 or IPv6 address.
    ///   - family: The family the encoded address claims to use.
    ///   - interfaceName: A nonempty interface name of at most 32 characters.
    ///   - kind: The role assigned to the interface.
    public init?(
        address: String,
        family: CmxIrohCustomPrivateAddress.Family,
        interfaceName: String,
        kind: Kind
    ) {
        let trimmedInterface = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInterface.isEmpty,
              trimmedInterface == interfaceName,
              trimmedInterface.count <= 32,
              let parsed = try? CmxIrohCustomPrivateAddress(address),
              parsed.family == family else {
            return nil
        }
        self.address = parsed.value
        self.family = parsed.family
        self.interfaceName = trimmedInterface
        self.kind = kind
    }

    /// Creates a validated discovered-address value while inferring its family.
    ///
    /// - Parameters:
    ///   - address: A numeric IPv4 or IPv6 address.
    ///   - interfaceName: A nonempty interface name of at most 32 characters.
    ///   - kind: The role assigned to the interface.
    public init?(address: String, interfaceName: String, kind: Kind) {
        guard let parsed = try? CmxIrohCustomPrivateAddress(address) else {
            return nil
        }
        self.init(
            address: parsed.value,
            family: parsed.family,
            interfaceName: interfaceName,
            kind: kind
        )
    }

    /// Classifies one interface/address pair for authenticated suggestion use.
    ///
    /// - Parameters:
    ///   - interfaceName: The operating-system interface name.
    ///   - address: A numeric IPv4 or IPv6 address.
    /// - Returns: A validated suggestion, or `nil` when the interface or address
    ///   is unsafe, public on a physical interface, or owned by Tailscale.
    public static func classify(
        interfaceName: String,
        address: String
    ) -> CmxPrivateNetworkAddress? {
        let normalizedInterface = interfaceName.lowercased()
        guard !excludedInterfacePrefixes.contains(where: normalizedInterface.hasPrefix),
              let parsed = try? CmxIrohCustomPrivateAddress(address) else {
            return nil
        }

        let kind = kind(for: normalizedInterface)
        switch parsed.family {
        case .ipv4:
            guard let bytes = CmxTailscalePeerAddress.parseIPv4(parsed.value)?.bytes,
                  CmxTailscalePeerAddress(parsed.value) == nil,
                  kind == .vpnTunnel || isPrivateIPv4(bytes) else {
                return nil
            }
        case .ipv6:
            guard let bytes = CmxTailscalePeerAddress.parseIPv6(parsed.value)?.bytes,
                  !CmxTailscalePeerAddress.isTailscaleIPv6Range(bytes),
                  kind == .vpnTunnel || isPrivateIPv6(bytes) else {
                return nil
            }
        }

        return CmxPrivateNetworkAddress(
            address: parsed.value,
            family: parsed.family,
            interfaceName: interfaceName,
            kind: kind
        )
    }

    /// Sorts and deduplicates discovered suggestions for stable display.
    ///
    /// VPN interfaces sort before local-network and other interfaces. Within a
    /// kind, candidates sort by interface name, IPv4 before IPv6, then address.
    ///
    /// - Parameter candidates: Validated discovered-address candidates.
    /// - Returns: A stable list deduplicated by interface name and address.
    public static func sorted(
        _ candidates: [CmxPrivateNetworkAddress]
    ) -> [CmxPrivateNetworkAddress] {
        let ordered = candidates.sorted { lhs, rhs in
            let lhsKind = kindSortOrder(lhs.kind)
            let rhsKind = kindSortOrder(rhs.kind)
            if lhsKind != rhsKind { return lhsKind < rhsKind }
            if lhs.interfaceName != rhs.interfaceName {
                return lhs.interfaceName < rhs.interfaceName
            }
            let lhsFamily = familySortOrder(lhs.family)
            let rhsFamily = familySortOrder(rhs.family)
            if lhsFamily != rhsFamily { return lhsFamily < rhsFamily }
            return lhs.address < rhs.address
        }
        var seen = Set<String>()
        return ordered.filter {
            seen.insert("\($0.interfaceName)\u{0}\($0.address)").inserted
        }
    }

    /// Decodes and revalidates a discovered address.
    ///
    /// - Parameter decoder: The decoder supplying the wire fields.
    /// - Throws: `DecodingError.dataCorrupted` for a malformed address,
    ///   mismatched family, or invalid interface name.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(
            address: try container.decode(String.self, forKey: .address),
            family: try container.decode(
                CmxIrohCustomPrivateAddress.Family.self,
                forKey: .family
            ),
            interfaceName: try container.decode(String.self, forKey: .interfaceName),
            kind: try container.decode(Kind.self, forKey: .kind)
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid private-network address"
                )
            )
        }
        self = value
    }

    /// Encodes the canonical discovered-address wire fields.
    ///
    /// - Parameter encoder: The encoder receiving the wire fields.
    /// - Throws: Any error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address, forKey: .address)
        try container.encode(family, forKey: .family)
        try container.encode(interfaceName, forKey: .interfaceName)
        try container.encode(kind, forKey: .kind)
    }

    private static let excludedInterfacePrefixes = [
        "awdl", "llw", "lo", "gif", "stf", "anpi", "pktap",
    ]
    private static let vpnInterfacePrefixes = [
        "utun", "ipsec", "ppp", "wg", "tun", "tap",
    ]
    private static let localNetworkInterfacePrefixes = [
        "en", "bridge", "bond", "av",
    ]

    private static func kind(for interfaceName: String) -> Kind {
        if vpnInterfacePrefixes.contains(where: interfaceName.hasPrefix) {
            return .vpnTunnel
        }
        if localNetworkInterfacePrefixes.contains(where: interfaceName.hasPrefix) {
            return .localNetwork
        }
        return .other
    }

    private static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10
            || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 100 && (bytes[1] & 0xC0) == 64)
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && (bytes[0] & 0xFE) == 0xFC
    }

    private static func kindSortOrder(_ kind: Kind) -> Int {
        switch kind {
        case .vpnTunnel: 0
        case .localNetwork: 1
        case .other: 2
        }
    }

    private static func familySortOrder(
        _ family: CmxIrohCustomPrivateAddress.Family
    ) -> Int {
        switch family {
        case .ipv4: 0
        case .ipv6: 1
        }
    }
}
