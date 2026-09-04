import Darwin
import CmuxFoundation
import Foundation

/// Host normalization and filtering rules for terminal-emitted links.
public struct CapturedLinkHostPolicy: Sendable {
    private let addressPolicy: NetworkAddressPolicy

    /// Creates a host policy backed by the shared network-address classifier.
    public init() {
        self.init(addressPolicy: NetworkAddressPolicy())
    }

    /// Creates a host policy with an injected network-address classifier.
    init(addressPolicy: NetworkAddressPolicy) {
        self.addressPolicy = addressPolicy
    }

    /// Returns a normalized `host` or `host:port` key for an URL string.
    ///
    /// - Parameter rawURL: The URL string to inspect.
    /// - Returns: A lowercased host key, preserving an explicit port when present.
    public func hostKey(for rawURL: String) -> String? {
        guard let components = URLComponents(string: rawURL),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }
        let normalizedHost = addressPolicy.normalizedHost(host)
        guard !normalizedHost.isEmpty else { return nil }
        if normalizedHost.contains(":") {
            let bracketedHost = "[\(normalizedHost)]"
            if let port = components.port {
                return "\(bracketedHost):\(port)"
            }
            return bracketedHost
        }
        if let port = components.port {
            return "\(normalizedHost):\(port)"
        }
        return normalizedHost
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
        guard let normalized = normalizeHostPort(hostPort) else { return false }
        let host = hostPart(of: normalized)
        for entry in list {
            guard let pattern = normalizePattern(entry) else { continue }
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(2))
                if host == suffix || host.hasSuffix(".\(suffix)") { return true }
            } else if patternContainsPort(pattern) {
                if normalized == pattern { return true }
            } else if host == hostPart(of: pattern) {
                return true
            }
        }
        return false
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

    private func normalizePattern(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("*.") {
            let suffix = String(trimmed.dropFirst(2))
            guard let normalizedSuffix = normalizeHostPort(suffix).map(hostPart(of:)) else { return nil }
            return "*.\(normalizedSuffix)"
        }
        return normalizeHostPort(trimmed)
    }

    private func normalizeHostPort(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "[", let closing = trimmed.firstIndex(of: "]") {
            let host = trimmed[trimmed.index(after: trimmed.startIndex)..<closing]
            guard !host.isEmpty else { return nil }
            let normalizedHost = addressPolicy.normalizedHost(String(host))
            guard !normalizedHost.isEmpty else { return nil }
            let rest = trimmed[trimmed.index(after: closing)...]
            guard !rest.isEmpty else { return "[\(normalizedHost)]" }
            if rest.first == ":",
               rest.dropFirst().allSatisfy(\.isNumber),
               !rest.dropFirst().isEmpty {
                return "[\(normalizedHost)]\(rest)"
            }
            return nil
        }
        let unbracketed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !unbracketed.isEmpty else { return nil }
        if unbracketed.contains(":") {
            let colonCount = unbracketed.filter { $0 == ":" }.count
            if colonCount == 1,
               let colon = unbracketed.lastIndex(of: ":"),
               unbracketed[unbracketed.index(after: colon)...].allSatisfy(\.isNumber) {
                let host = addressPolicy.normalizedHost(String(unbracketed[..<colon]))
                guard !host.isEmpty else { return nil }
                return "\(host)\(unbracketed[colon...])"
            }
            return "[\(addressPolicy.normalizedHost(unbracketed))]"
        }
        return addressPolicy.normalizedHost(unbracketed)
    }

    /// Returns the host portion of a normalized `host` or `host:port` key.
    ///
    /// - Parameter hostPort: The normalized host key.
    /// - Returns: The host without a port suffix.
    public func hostPart(of hostPort: String) -> String {
        if hostPort.first == "[", let closing = hostPort.firstIndex(of: "]") {
            return String(hostPort[hostPort.index(after: hostPort.startIndex)..<closing])
        }
        let colonCount = hostPort.filter { $0 == ":" }.count
        if colonCount == 1,
           let colon = hostPort.lastIndex(of: ":"),
           hostPort[hostPort.index(after: colon)...].allSatisfy(\.isNumber) {
            return String(hostPort[..<colon])
        }
        return hostPort
    }

    private func patternContainsPort(_ pattern: String) -> Bool {
        if pattern.first == "[", let closing = pattern.firstIndex(of: "]") {
            let rest = pattern[pattern.index(after: closing)...]
            return rest.first == ":" &&
                rest.dropFirst().allSatisfy(\.isNumber) &&
                !rest.dropFirst().isEmpty
        }
        let colonCount = pattern.filter { $0 == ":" }.count
        guard colonCount == 1, let colon = pattern.lastIndex(of: ":") else { return false }
        return pattern[pattern.index(after: colon)...].allSatisfy(\.isNumber)
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
