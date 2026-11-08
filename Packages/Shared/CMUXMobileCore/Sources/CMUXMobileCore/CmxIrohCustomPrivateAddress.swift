import Darwin
import Foundation

/// One canonical numeric address for a user-configured private path.
///
/// This value intentionally carries no port or identity. Dial-time policy joins
/// it to the broker-authenticated Mac's current Iroh UDP port and EndpointID.
public struct CmxIrohCustomPrivateAddress: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case value
        case family
    }
    public enum Family: String, Codable, Sendable {
        case ipv4
        case ipv6
    }

    /// Canonical numeric IPv4 or IPv6 text without brackets, a port, or a zone.
    public let value: String
    public let family: Family

    /// Parses, canonicalizes, and validates one numeric private-path address.
    ///
    /// Hostnames, socket ports, loopback, multicast, link-local, wildcard, and
    /// scoped IPv6 addresses are rejected. Globally shaped addresses remain
    /// eligible because the authenticated Iroh handshake, not the coordinate,
    /// proves the remote Mac.
    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 64,
              !trimmed.contains("%"),
              !trimmed.contains("["),
              !trimmed.contains("]") else {
            throw CmxIrohCustomPrivateAddressError.invalidAddress
        }

        let canonical: String
        let family: Family
        if let value = Self.canonicalIPv4(trimmed) {
            canonical = value
            family = .ipv4
        } else if let value = Self.canonicalIPv6(trimmed) {
            canonical = value
            family = .ipv6
        } else {
            throw CmxIrohCustomPrivateAddressError.invalidAddress
        }

        do {
            let profile = try CmxIrohNetworkProfileKey(
                source: .customVPN,
                profileID: String(repeating: "0", count: 64)
            )
            let observedAt = Date(timeIntervalSince1970: 0)
            _ = try CmxIrohPathHint(
                kind: .directAddress,
                value: family == .ipv4 ? "\(canonical):1" : "[\(canonical)]:1",
                source: .customVPN,
                privacyScope: .privateNetwork,
                observedAt: observedAt,
                expiresAt: observedAt.addingTimeInterval(1),
                networkProfile: profile
            )
        } catch {
            throw CmxIrohCustomPrivateAddressError.invalidAddress
        }

        self.value = canonical
        self.family = family
    }

    /// Builds the Iroh socket coordinate using an authenticated UDP port.
    public func socketAddress(port: UInt16) -> String {
        switch family {
        case .ipv4: "\(value):\(port)"
        case .ipv6: "[\(value)]:\(port)"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFamily = try container.decode(Family.self, forKey: .family)
        try self.init(container.decode(String.self, forKey: .value))
        guard family == decodedFamily else {
            throw CmxIrohCustomPrivateAddressError.invalidAddress
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(family, forKey: .family)
    }

    private static func canonicalIPv4(_ rawValue: String) -> String? {
        var address = in_addr()
        guard rawValue.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return Self.string(beforeNullIn: buffer)
    }

    private static func canonicalIPv6(_ rawValue: String) -> String? {
        var address = in6_addr()
        guard rawValue.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        return Self.string(beforeNullIn: buffer)
    }

    private static func string(beforeNullIn buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum CmxIrohCustomPrivateAddressError: Error, Equatable, Sendable {
    case invalidAddress
}
