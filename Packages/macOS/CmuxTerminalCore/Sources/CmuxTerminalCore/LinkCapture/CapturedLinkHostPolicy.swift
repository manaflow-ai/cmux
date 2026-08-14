import Foundation

/// Host normalization and filtering rules for terminal-emitted links.
public enum CapturedLinkHostPolicy {
    /// Returns a normalized `host` or `host:port` key for an URL string.
    ///
    /// - Parameter rawURL: The URL string to inspect.
    /// - Returns: A lowercased host key, preserving an explicit port when present.
    public static func hostKey(for rawURL: String) -> String? {
        guard let components = URLComponents(string: rawURL),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !normalizedHost.isEmpty else { return nil }
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
    public static func matchesIgnoreList(hostPort: String?, list: [String]) -> Bool {
        guard let normalized = normalizeHostPort(hostPort) else { return false }
        let host = hostPart(of: normalized)
        for entry in list {
            guard let pattern = normalizePattern(entry) else { continue }
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(2))
                if host == suffix || host.hasSuffix(".\(suffix)") { return true }
            } else if patternContainsPort(pattern) {
                if normalized == pattern { return true }
            } else if host == pattern {
                return true
            }
        }
        return false
    }

    /// Checks whether a host is private, loopback, link-local, or local-only.
    ///
    /// - Parameter host: A host without scheme.
    /// - Returns: Whether title fetching should be refused for this host.
    public static func isPrivateOrLocalHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "localhost" || normalized.hasSuffix(".local") { return true }
        if isPrivateIPv4(normalized) { return true }
        if isPrivateIPv6(normalized) { return true }
        return false
    }

    private static func normalizePattern(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("*.") {
            let suffix = String(trimmed.dropFirst(2))
            guard let normalizedSuffix = normalizeHostPort(suffix).map(hostPart(of:)) else { return nil }
            return "*.\(normalizedSuffix)"
        }
        return normalizeHostPort(trimmed)
    }

    private static func normalizeHostPort(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Returns the host portion of a normalized `host` or `host:port` key.
    ///
    /// - Parameter hostPort: The normalized host key.
    /// - Returns: The host without a port suffix.
    public static func hostPart(of hostPort: String) -> String {
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

    private static func patternContainsPort(_ pattern: String) -> Bool {
        let colonCount = pattern.filter { $0 == ":" }.count
        guard colonCount == 1, let colon = pattern.lastIndex(of: ":") else { return false }
        return pattern[pattern.index(after: colon)...].allSatisfy(\.isNumber)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let pieces = host.split(separator: ".")
        guard pieces.count == 4,
              let a = UInt8(pieces[0]),
              let b = UInt8(pieces[1]),
              UInt8(pieces[2]) != nil,
              UInt8(pieces[3]) != nil else {
            return false
        }
        if a == 127 || a == 10 || a == 169 && b == 254 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(Int(b)) { return true }
        return false
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        let lower = host.lowercased()
        guard lower.contains(":") else { return false }
        if lower == "::1" || lower.hasPrefix("::1:") { return true }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") ||
            lower.hasPrefix("fea") || lower.hasPrefix("feb") {
            return true
        }
        return false
    }
}
