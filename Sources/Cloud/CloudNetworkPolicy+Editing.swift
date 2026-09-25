import Foundation

/// One change to a ``CloudNetworkPolicy``. The editor sheet, the New Machine
/// sheet, and `cmux vm network` all express their changes as edits and apply
/// them through ``CloudNetworkPolicy/apply(_:knownPresetIDs:)``, so every
/// entrypoint shares one set of rules.
enum CloudNetworkPolicyEdit: Equatable, Sendable {
    case setMode(CloudNetworkPolicyMode)
    case addDomain(String)
    case removeDomain(String)
    case addRange(CloudNetworkRange)
    case removeRange(CloudNetworkRange)
    case setPreset(String, enabled: Bool)
    case setAllowDns(Bool)
    case replace(CloudNetworkPolicy)
}

/// Why an edit was refused before it reached the server.
enum CloudNetworkPolicyEditError: Error, Equatable, LocalizedError, Sendable {
    case invalidDomain(String)
    case wildcardDomain(String)
    case duplicateDomain(String)
    case missingDomain(String)
    case tooManyDomains
    case invalidRange(String)
    case invalidPort
    case duplicateRange(String)
    case missingRange(String)
    case tooManyRanges
    case noteTooLong
    case unknownPreset(String)

    var errorDescription: String? {
        switch self {
        case .invalidDomain(let value):
            return String(format: String(localized: "cloud.network.error.invalidDomain", defaultValue: "“%@” is not a host name."), value)
        case .wildcardDomain(let value):
            return String(format: String(localized: "cloud.network.error.wildcardDomain", defaultValue: "“%@”: wildcards are not supported yet. List each exact name."), value)
        case .duplicateDomain(let value):
            return String(format: String(localized: "cloud.network.error.duplicateDomain", defaultValue: "%@ is already in the list."), value)
        case .missingDomain(let value):
            return String(format: String(localized: "cloud.network.error.missingDomain", defaultValue: "%@ is not in the list."), value)
        case .tooManyDomains:
            return String(localized: "cloud.network.error.tooManyDomains", defaultValue: "The domain list is full.")
        case .invalidRange(let value):
            return String(format: String(localized: "cloud.network.error.invalidRange", defaultValue: "“%@” is not an IPv4 or IPv6 range."), value)
        case .invalidPort:
            return String(localized: "cloud.network.error.invalidPort", defaultValue: "The port must be a number from 1 to 65535.")
        case .duplicateRange(let value):
            return String(format: String(localized: "cloud.network.error.duplicateRange", defaultValue: "%@ is already in the list."), value)
        case .missingRange(let value):
            return String(format: String(localized: "cloud.network.error.missingRange", defaultValue: "%@ is not in the list."), value)
        case .tooManyRanges:
            return String(localized: "cloud.network.error.tooManyRanges", defaultValue: "The IP range list is full.")
        case .noteTooLong:
            return String(localized: "cloud.network.error.noteTooLong", defaultValue: "The note is too long.")
        case .unknownPreset(let value):
            return String(format: String(localized: "cloud.network.error.unknownPreset", defaultValue: "Unknown preset “%@”."), value)
        }
    }
}

extension CloudNetworkPolicy {
    /// Applies one edit. `knownPresetIDs` is the server's preset catalog; nil
    /// skips the preset check (the server still validates).
    mutating func apply(_ edit: CloudNetworkPolicyEdit, knownPresetIDs: Set<String>? = nil) throws {
        switch edit {
        case .setMode(let mode):
            // Lists survive a mode switch so switching back restores them.
            self.mode = mode
        case .addDomain(let raw):
            let domain = try Self.normalizedDomain(raw)
            guard !domains.contains(domain) else { throw CloudNetworkPolicyEditError.duplicateDomain(domain) }
            guard domains.count < Self.maxDomains else { throw CloudNetworkPolicyEditError.tooManyDomains }
            domains.append(domain)
        case .removeDomain(let raw):
            let domain = (try? Self.normalizedDomain(raw)) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let index = domains.firstIndex(of: domain) else { throw CloudNetworkPolicyEditError.missingDomain(domain) }
            domains.remove(at: index)
        case .addRange(let raw):
            let range = try Self.normalizedRange(raw)
            guard !ranges.contains(where: { $0.identityKey == range.identityKey }) else {
                throw CloudNetworkPolicyEditError.duplicateRange(range.displayText)
            }
            guard ranges.count < Self.maxRanges else { throw CloudNetworkPolicyEditError.tooManyRanges }
            ranges.append(range)
        case .removeRange(let raw):
            let target = (try? Self.normalizedRange(raw)) ?? raw
            // A bare CIDR with no port removes every rule on that range.
            let matches: (CloudNetworkRange) -> Bool = raw.port == nil && raw.transport == nil
                ? { $0.cidr == target.cidr }
                : { $0.identityKey == target.identityKey }
            guard ranges.contains(where: matches) else { throw CloudNetworkPolicyEditError.missingRange(raw.displayText) }
            ranges.removeAll(where: matches)
        case .setPreset(let id, let enabled):
            if enabled {
                if let knownPresetIDs, !knownPresetIDs.contains(id) { throw CloudNetworkPolicyEditError.unknownPreset(id) }
                if !presets.contains(id) { presets.append(id) }
            } else {
                presets.removeAll { $0 == id }
            }
        case .setAllowDns(let allow):
            allowDns = allow
        case .replace(let policy):
            self = policy
        }
    }

    /// Mirrors the server's `parseDomain`: lowercase, drop a scheme, a path,
    /// and a trailing dot, then require an exact host name.
    static func normalizedDomain(_ raw: String) throws -> String {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where domain.hasPrefix(scheme) {
            domain.removeFirst(scheme.count)
        }
        if let slash = domain.firstIndex(of: "/") { domain = String(domain[..<slash]) }
        if domain.hasSuffix(".") { domain.removeLast() }
        if domain.contains("*") { throw CloudNetworkPolicyEditError.wildcardDomain(raw) }
        guard isHostName(domain) else { throw CloudNetworkPolicyEditError.invalidDomain(raw) }
        return domain
    }

    /// Validates the range locally and stores the canonical CIDR: host bits
    /// cleared, a bare address as /32 or /128. A port without a protocol means TCP.
    static func normalizedRange(_ raw: CloudNetworkRange) throws -> CloudNetworkRange {
        guard let canonical = canonicalCIDR(raw.cidr) else { throw CloudNetworkPolicyEditError.invalidRange(raw.cidr) }
        if let port = raw.port, !(1...65_535).contains(port) { throw CloudNetworkPolicyEditError.invalidPort }
        let note = raw.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note, note.count > maxNoteLength { throw CloudNetworkPolicyEditError.noteTooLong }
        return CloudNetworkRange(
            cidr: canonical,
            port: raw.port,
            transport: raw.port == nil ? raw.transport : (raw.transport ?? .tcp),
            note: note?.isEmpty == false ? note : nil
        )
    }

    static func canonicalCIDR(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty else { return nil }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber), parts[1].count <= 3 else { return nil }
        }
        guard let prefix = IPNetworkPrefix(cidr: trimmed) else { return nil }
        let family = prefix.family == .v4 ? AF_INET : AF_INET6
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let formatted: String? = prefix.network.withUnsafeBytes { raw in
            guard inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        guard let formatted else { return nil }
        return "\(formatted)/\(prefix.prefixLength)"
    }

    private static let hostNamePattern = try? NSRegularExpression(
        pattern: #"^(?=.{1,253}$)(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$"#
    )

    private static func isHostName(_ value: String) -> Bool {
        guard let hostNamePattern else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return hostNamePattern.firstMatch(in: value, range: range) != nil
    }
}
