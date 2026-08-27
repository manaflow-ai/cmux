import Darwin
import Foundation

/// One canonical, numeric Iroh UDP address safe to advertise on a local link.
public struct CmxIrohLANSocketAddress: Equatable, Hashable, Sendable {
    public enum Family: Equatable, Hashable, Sendable {
        case ipv4
        case ipv6
    }

    /// Canonical `IPv4:port` or `[IPv6]:port` wire representation.
    public let value: String
    /// Canonical unbracketed IP literal.
    public let ipAddress: String
    public let port: UInt16
    public let family: Family

    let addressBytes: [UInt8]

    /// Parses a canonical, non-loopback, non-link-local unicast socket address.
    public init(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 80 else {
            throw CmxIrohLANDiscoveryError.invalidSocketAddress
        }

        let host: String
        let portText: String
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]"),
                  value.index(after: closing) < value.endIndex,
                  value[value.index(after: closing)] == ":" else {
                throw CmxIrohLANDiscoveryError.invalidSocketAddress
            }
            host = String(value[value.index(after: value.startIndex)..<closing])
            portText = String(value[value.index(closing, offsetBy: 2)...])
        } else {
            guard let separator = value.lastIndex(of: ":"),
                  !value[..<separator].contains(":") else {
                throw CmxIrohLANDiscoveryError.invalidSocketAddress
            }
            host = String(value[..<separator])
            portText = String(value[value.index(after: separator)...])
        }
        guard !portText.isEmpty,
              portText.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let portValue = UInt16(portText),
              portValue != 0,
              String(portValue) == portText else {
            throw CmxIrohLANDiscoveryError.invalidSocketAddress
        }

        if let parsed = Self.parseIPv4(host) {
            guard !Self.isForbiddenIPv4(parsed.bytes), value == "\(parsed.canonical):\(portValue)" else {
                throw CmxIrohLANDiscoveryError.invalidSocketAddress
            }
            self.value = value
            ipAddress = parsed.canonical
            port = portValue
            family = .ipv4
            addressBytes = parsed.bytes
            return
        }
        if let parsed = Self.parseIPv6(host) {
            guard !Self.isForbiddenIPv6(parsed.bytes), value == "[\(parsed.canonical)]:\(portValue)" else {
                throw CmxIrohLANDiscoveryError.invalidSocketAddress
            }
            self.value = value
            ipAddress = parsed.canonical
            port = portValue
            family = .ipv6
            addressBytes = parsed.bytes
            return
        }
        throw CmxIrohLANDiscoveryError.invalidSocketAddress
    }

    static func wildcard(_ value: String) -> (family: Family, port: UInt16)? {
        if value.hasPrefix("0.0.0.0:"),
           let port = UInt16(value.dropFirst("0.0.0.0:".count)),
           port != 0,
           value == "0.0.0.0:\(port)" {
            return (.ipv4, port)
        }
        if value.hasPrefix("[::]:"),
           let port = UInt16(value.dropFirst("[::]:".count)),
           port != 0,
           value == "[::]:\(port)" {
            return (.ipv6, port)
        }
        return nil
    }

    static func canonicalValue(ipAddress: String, port: UInt16) -> String {
        ipAddress.contains(":") ? "[\(ipAddress)]:\(port)" : "\(ipAddress):\(port)"
    }

    private static func parseIPv4(_ value: String) -> (canonical: String, bytes: [UInt8])? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return (Self.decode(buffer), bytes)
    }

    private static func parseIPv6(_ value: String) -> (canonical: String, bytes: [UInt8])? {
        guard !value.contains("%") else { return nil }
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return (Self.decode(buffer).lowercased(), bytes)
    }

    private static func decode(_ buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func isForbiddenIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        return bytes[0] == 0
            || bytes[0] == 127
            || bytes[0] >= 224
            || (bytes[0] == 169 && bytes[1] == 254)
            || bytes == [255, 255, 255, 255]
    }

    private static func isForbiddenIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 })
            || bytes == Array(repeating: 0, count: 15) + [1]
            || bytes[0] == 0xFF {
            return true
        }
        if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return true }
        let mapped = Array(repeating: UInt8(0), count: 10) + [0xFF, 0xFF]
        if Array(bytes.prefix(12)) == mapped {
            return isForbiddenIPv4(Array(bytes.suffix(4)))
        }
        return false
    }
}
