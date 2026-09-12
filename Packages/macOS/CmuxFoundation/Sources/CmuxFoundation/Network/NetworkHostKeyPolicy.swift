import Foundation

/// Bracket-aware `host` / `host:port` keys and ignore-list matching.
///
/// Terminal link capture and the Artifacts catalog accept the same
/// user-facing ignore list (`host`, `host:port`, `*.suffix`), so both derive
/// keys and match entries through this one policy instead of splitting
/// authorities on colons independently. IPv6 literals keep their brackets
/// (`[::1]:8080`) so the port is unambiguous.
public struct NetworkHostKeyPolicy: Sendable {
    private let addressPolicy: NetworkAddressPolicy

    /// Creates a host-key policy backed by the shared network-address classifier.
    ///
    /// - Parameter addressPolicy: The classifier used to normalize host spellings.
    public init(addressPolicy: NetworkAddressPolicy = NetworkAddressPolicy()) {
        self.addressPolicy = addressPolicy
    }

    /// Returns a normalized `host` or `host:port` key for a URL string.
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

    /// Returns the host portion of a normalized `host` or `host:port` key.
    ///
    /// - Parameter hostPort: The normalized host key.
    /// - Returns: The host without brackets or a port suffix.
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
}
