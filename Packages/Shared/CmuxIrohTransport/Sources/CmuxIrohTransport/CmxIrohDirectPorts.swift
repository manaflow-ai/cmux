import CMUXMobileCore

/// The endpoint-observed UDP ports for private IPv4 and IPv6 Iroh paths.
///
/// The broker may disclose these ports only to the same authenticated account.
/// A port contains no private address and never contributes peer identity or
/// authorization. Clients combine it with a locally known private address and
/// still pin the QUIC handshake to the broker-authenticated EndpointID.
public struct CmxIrohDirectPorts: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case ipv4
        case ipv6
    }

    public let ipv4: UInt16?
    public let ipv6: UInt16?

    public init(ipv4: UInt16? = nil, ipv6: UInt16? = nil) throws {
        guard ipv4 != nil || ipv6 != nil,
              ipv4.map({ $0 != 0 }) ?? true,
              ipv6.map({ $0 != 0 }) ?? true else {
            throw CmxIrohDirectPortsError.empty
        }
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            ipv4: container.decodeIfPresent(UInt16.self, forKey: .ipv4),
            ipv6: container.decodeIfPresent(UInt16.self, forKey: .ipv6)
        )
    }

    /// Derives one unambiguous socket port per address family from the endpoint.
    ///
    /// Iroh may bind IPv4 and IPv6 independently. If one family reports more
    /// than one port, that family is omitted rather than guessing which private
    /// coordinate is authoritative.
    init?(localDirectAddresses: [String]) {
        var ipv4Ports: Set<UInt16> = []
        var ipv6Ports: Set<UInt16> = []
        var ipv4WildcardPorts: Set<UInt16> = []
        var ipv6WildcardPorts: Set<UInt16> = []
        for rawAddress in localDirectAddresses {
            if let wildcard = CmxIrohLANSocketAddress.wildcard(rawAddress) {
                switch wildcard.family {
                case .ipv4:
                    ipv4Ports.insert(wildcard.port)
                    ipv4WildcardPorts.insert(wildcard.port)
                case .ipv6:
                    ipv6Ports.insert(wildcard.port)
                    ipv6WildcardPorts.insert(wildcard.port)
                }
                continue
            }
            guard let address = try? CmxIrohLANSocketAddress(rawAddress) else {
                continue
            }
            switch address.family {
            case .ipv4: ipv4Ports.insert(address.port)
            case .ipv6: ipv6Ports.insert(address.port)
            }
        }
        let ipv4 = Self.authoritativePort(
            wildcardPorts: ipv4WildcardPorts,
            observedPorts: ipv4Ports
        )
        let ipv6 = Self.authoritativePort(
            wildcardPorts: ipv6WildcardPorts,
            observedPorts: ipv6Ports
        )
        guard ipv4 != nil || ipv6 != nil else { return nil }
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    func port(forDirectAddress value: String) -> UInt16? {
        value.hasPrefix("[") ? ipv6 : ipv4
    }

    private static func authoritativePort(
        wildcardPorts: Set<UInt16>,
        observedPorts: Set<UInt16>
    ) -> UInt16? {
        if wildcardPorts.count == 1 { return wildcardPorts.first }
        return observedPorts.count == 1 ? observedPorts.first : nil
    }

    func replacingPort(in hint: CmxIrohPathHint) -> CmxIrohPathHint? {
        guard hint.kind == .directAddress,
              hint.privacyScope != .publicInternet,
              hint.source == .tailscale || hint.source == .customVPN else {
            return hint
        }
        guard let port = port(forDirectAddress: hint.value),
              let separator = hint.value.lastIndex(of: ":") else { return nil }
        let value = String(hint.value[...separator]) + String(port)
        return try? CmxIrohPathHint(
            kind: hint.kind,
            value: value,
            source: hint.source,
            privacyScope: hint.privacyScope,
            observedAt: hint.observedAt,
            expiresAt: hint.expiresAt,
            networkProfile: hint.networkProfile
        )
    }
}

public enum CmxIrohDirectPortsError: Error, Equatable, Sendable {
    case empty
}
