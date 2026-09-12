import Darwin
import CmuxFoundation
import Foundation

/// Host normalization and filtering rules for terminal-emitted links.
///
/// Host keys and ignore-list matching are delegated to the shared
/// ``NetworkHostKeyPolicy`` so the Artifacts catalog applies the exact same
/// rules to the same user-facing ignore list.
public struct CapturedLinkHostPolicy: Sendable {
    private let addressPolicy: NetworkAddressPolicy
    private let hostKeyPolicy: NetworkHostKeyPolicy

    /// Creates a host policy backed by the shared network-address classifier.
    public init() {
        self.init(addressPolicy: NetworkAddressPolicy())
    }

    /// Creates a host policy with an injected network-address classifier.
    init(addressPolicy: NetworkAddressPolicy) {
        self.addressPolicy = addressPolicy
        self.hostKeyPolicy = NetworkHostKeyPolicy(addressPolicy: addressPolicy)
    }

    /// Returns a normalized `host` or `host:port` key for an URL string.
    ///
    /// - Parameter rawURL: The URL string to inspect.
    /// - Returns: A lowercased host key, preserving an explicit port when present.
    public func hostKey(for rawURL: String) -> String? {
        hostKeyPolicy.hostKey(for: rawURL)
    }

    /// Checks whether a normalized host key matches an ignore-list.
    ///
    /// Entries are comma-split by the caller or can be passed as raw strings:
    /// `host` matches all ports, `host:port` matches exactly, and
    /// `*.example.com` matches the suffix and the bare suffix host.
    ///
    /// - Parameters:
    ///   - hostPort: A normalized `host` or `host:port` key.
    ///   - list: Ignore-list entries.
    /// - Returns: Whether the host key is ignored.
    public func matchesIgnoreList(hostPort: String?, list: [String]) -> Bool {
        hostKeyPolicy.matchesIgnoreList(hostPort: hostPort, list: list)
    }

    /// Checks whether a host is private, loopback, link-local, or local-only.
    ///
    /// - Parameter host: A host without scheme.
    /// - Returns: Whether title fetching should be refused for this host.
    public func isPrivateOrLocalHost(_ host: String) -> Bool {
        !addressPolicy.allowsPublicInternetHost(host)
    }

    func isPrivateOrLocalAddress(_ address: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                isPrivateOrLocalIPv4Address(ipv4Octets(from: pointer.pointee.sin_addr))
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                isPrivateOrLocalIPv6Address(ipv6Bytes(from: pointer.pointee.sin6_addr))
            }
        default:
            return true
        }
    }

    /// Checks whether IPv4 address octets are private, loopback, link-local, or local-only.
    ///
    /// - Parameter octets: Four IPv4 address bytes in network order.
    /// - Returns: Whether title fetching should be refused for this address.
    public func isPrivateOrLocalIPv4Address(_ octets: [UInt8]) -> Bool {
        !addressPolicy.allowsPublicIPv4Address(octets)
    }

    /// Checks whether IPv6 address bytes are private, loopback, link-local, or local-only.
    ///
    /// - Parameter bytes: Sixteen IPv6 address bytes in network order.
    /// - Returns: Whether title fetching should be refused for this address.
    public func isPrivateOrLocalIPv6Address(_ bytes: [UInt8]) -> Bool {
        !addressPolicy.allowsPublicIPv6Address(bytes)
    }

    /// Returns the host portion of a normalized `host` or `host:port` key.
    ///
    /// - Parameter hostPort: The normalized host key.
    /// - Returns: The host without a port suffix.
    public func hostPart(of hostPort: String) -> String {
        hostKeyPolicy.hostPart(of: hostPort)
    }

    private func ipv4Octets(from address: in_addr) -> [UInt8] {
        let value = UInt32(bigEndian: address.s_addr)
        return [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private func ipv6Bytes(from address: in6_addr) -> [UInt8] {
        withUnsafeBytes(of: address) { Array($0) }
    }
}
