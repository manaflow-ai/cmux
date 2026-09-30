import Darwin
public import Foundation

/// The outbound policy accepted by the Cloud machine create API.
public struct CloudNetworkPolicy: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxRanges = 64
    public static let maxDomains = 128
    public static let maxNoteLength = 120

    public static let `default` = CloudNetworkPolicy(mode: .full)

    public var version: Int
    public var mode: CloudNetworkPolicyMode
    public var ranges: [CloudNetworkRange]
    public var domains: [String]
    public var presets: [String]
    public var allowDns: Bool

    public init(
        mode: CloudNetworkPolicyMode,
        ranges: [CloudNetworkRange] = [],
        domains: [String] = [],
        presets: [String] = [],
        allowDns: Bool = true
    ) {
        self.version = Self.currentVersion
        self.mode = mode
        self.ranges = ranges
        self.domains = domains
        self.presets = presets
        self.allowDns = allowDns
    }

    private enum CodingKeys: String, CodingKey {
        case version, mode, ranges, domains, presets, allowDns
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        mode = try container.decode(CloudNetworkPolicyMode.self, forKey: .mode)
        ranges = try container.decodeIfPresent([CloudNetworkRange].self, forKey: .ranges) ?? []
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
        presets = try container.decodeIfPresent([String].self, forKey: .presets) ?? []
        allowDns = try container.decodeIfPresent(Bool.self, forKey: .allowDns) ?? true
    }

    public var foundationObject: [String: Any] {
        [
            "version": version,
            "mode": mode.rawValue,
            "ranges": ranges.map(\.foundationObject),
            "domains": domains,
            "presets": presets,
            "allowDns": allowDns,
        ]
    }

    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

public enum CloudNetworkPolicyMode: String, Codable, CaseIterable, Sendable {
    case full
    case allowlist
    case none

    public var title: String {
        switch self {
        case .full: return String(localized: "mobile.cloud.network.full", defaultValue: "Full internet")
        case .allowlist: return String(localized: "mobile.cloud.network.allowlist", defaultValue: "Allowlist")
        case .none: return String(localized: "mobile.cloud.network.none", defaultValue: "No internet")
        }
    }

    public var explanation: String {
        switch self {
        case .full:
            return String(localized: "mobile.cloud.network.full.detail", defaultValue: "The machine can reach any public address.")
        case .allowlist:
            return String(localized: "mobile.cloud.network.allowlist.detail", defaultValue: "Only listed domains and IP ranges, plus what cmux needs.")
        case .none:
            return String(localized: "mobile.cloud.network.none.detail", defaultValue: "No outbound access except what cmux itself needs.")
        }
    }
}

public enum CloudNetworkRangeProtocol: String, Codable, CaseIterable, Sendable {
    case tcp
    case udp
}

public struct CloudNetworkRange: Codable, Equatable, Hashable, Sendable {
    public var cidr: String
    public var port: Int?
    public var transport: CloudNetworkRangeProtocol?
    public var note: String?

    public init(
        cidr: String,
        port: Int? = nil,
        transport: CloudNetworkRangeProtocol? = nil,
        note: String? = nil
    ) {
        self.cidr = cidr
        self.port = port
        self.transport = transport
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case cidr, port, note
        case transport = "protocol"
    }

    public var identityKey: String {
        "\(cidr)|\(port.map(String.init) ?? "")|\(transport?.rawValue ?? "")"
    }

    public var displayText: String {
        guard let port else { return cidr }
        return "\(cidr) \(transport?.rawValue ?? CloudNetworkRangeProtocol.tcp.rawValue)/\(port)"
    }

    public var foundationObject: [String: Any] {
        var object: [String: Any] = ["cidr": cidr]
        if let port { object["port"] = port }
        if let transport { object["protocol"] = transport.rawValue }
        if let note, !note.isEmpty { object["note"] = note }
        return object
    }
}

public struct CloudNetworkPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let domains: [String]

    public init(id: String, label: String, domains: [String]) {
        self.id = id
        self.label = label
        self.domains = domains
    }
}

/// The catalog returned by `GET /api/vm/network-presets`.
public struct CloudNetworkPresetCatalog: Codable, Equatable, Sendable {
    public let presets: [CloudNetworkPreset]
    public let requiredDomains: [String]
    public let defaultPolicy: CloudNetworkPolicy
    public let agentUpdateDomains: [String]

    public static let legacyAgentUpdateDomains = ["registry.npmjs.org"]

    private enum CodingKeys: String, CodingKey {
        case presets, requiredDomains, defaultPolicy, agentUpdateDomains
    }

    public init(
        presets: [CloudNetworkPreset],
        requiredDomains: [String],
        defaultPolicy: CloudNetworkPolicy = .default,
        agentUpdateDomains: [String] = Self.legacyAgentUpdateDomains
    ) {
        self.presets = presets
        self.requiredDomains = requiredDomains
        self.defaultPolicy = defaultPolicy
        self.agentUpdateDomains = agentUpdateDomains
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presets = try container.decodeIfPresent([CloudNetworkPreset].self, forKey: .presets) ?? []
        requiredDomains = try container.decodeIfPresent([String].self, forKey: .requiredDomains) ?? []
        defaultPolicy = try container.decodeIfPresent(CloudNetworkPolicy.self, forKey: .defaultPolicy) ?? .default
        agentUpdateDomains = try container.decodeIfPresent([String].self, forKey: .agentUpdateDomains)
            ?? Self.legacyAgentUpdateDomains
    }
}

public enum CloudAgentUpdates: String, Codable, CaseIterable, Sendable {
    case image
    case latest

    public init?(wireValue: Any?) {
        guard let raw = wireValue as? String else { return nil }
        self.init(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public init(keepsAgentsUpdated: Bool) {
        self = keepsAgentsUpdated ? .latest : .image
    }

    public var keepsAgentsUpdated: Bool {
        self == .latest
    }

    public func blockedDomains(
        for policy: CloudNetworkPolicy,
        catalog: CloudNetworkPresetCatalog
    ) -> [String] {
        guard self == .latest else { return [] }
        return catalog.agentUpdateDomains.filter { !policy.allows($0, catalog: catalog) }
    }
}

extension CloudNetworkPolicy {
    public mutating func setMode(_ mode: CloudNetworkPolicyMode) {
        self.mode = mode
    }

    public mutating func setPreset(_ id: String, enabled: Bool) {
        if enabled {
            if !presets.contains(id) { presets.append(id) }
        } else {
            presets.removeAll { $0 == id }
        }
    }

    public mutating func addDomain(_ raw: String) throws {
        let domain = try Self.normalizedDomain(raw)
        guard !domains.contains(domain) else { throw CloudNetworkPolicyEditError.duplicateDomain(domain) }
        guard domains.count < Self.maxDomains else { throw CloudNetworkPolicyEditError.tooManyDomains }
        domains.append(domain)
    }

    public mutating func removeDomain(_ raw: String) {
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        domains.removeAll { $0 == domain }
    }

    public mutating func addRange(_ raw: CloudNetworkRange) throws {
        let range = try Self.normalizedRange(raw)
        guard !ranges.contains(where: { $0.identityKey == range.identityKey }) else {
            throw CloudNetworkPolicyEditError.duplicateRange(range.displayText)
        }
        guard ranges.count < Self.maxRanges else { throw CloudNetworkPolicyEditError.tooManyRanges }
        ranges.append(range)
    }

    public mutating func removeRange(_ range: CloudNetworkRange) {
        ranges.removeAll { $0.identityKey == range.identityKey }
    }

    public static func normalizedDomain(_ raw: String) throws -> String {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where domain.hasPrefix(scheme) {
            domain.removeFirst(scheme.count)
        }
        if let slash = domain.firstIndex(of: "/") {
            domain = String(domain[..<slash])
        }
        if domain.hasSuffix(".") {
            domain.removeLast()
        }
        guard !domain.contains("*"), isHostName(domain) else {
            throw CloudNetworkPolicyEditError.invalidDomain(raw)
        }
        return domain
    }

    public static func normalizedRange(_ raw: CloudNetworkRange) throws -> CloudNetworkRange {
        guard let cidr = canonicalCIDR(raw.cidr) else {
            throw CloudNetworkPolicyEditError.invalidRange(raw.cidr)
        }
        if let port = raw.port, !(1...65_535).contains(port) {
            throw CloudNetworkPolicyEditError.invalidPort
        }
        let note = raw.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note?.count ?? 0 <= maxNoteLength else {
            throw CloudNetworkPolicyEditError.noteTooLong
        }
        return CloudNetworkRange(
            cidr: cidr,
            port: raw.port,
            transport: raw.port == nil ? raw.transport : (raw.transport ?? .tcp),
            note: note?.isEmpty == false ? note : nil
        )
    }

    public func allows(_ domain: String, catalog: CloudNetworkPresetCatalog) -> Bool {
        if mode == .full || catalog.requiredDomains.contains(domain) {
            return true
        }
        guard mode == .allowlist else { return false }
        return domains.contains(domain)
            || catalog.presets.contains {
                presets.contains($0.id) && $0.domains.contains(domain)
            }
    }

    /// Stores the same canonical CIDR the Mac editor and server use: a bare
    /// address gets its host prefix, and host bits are cleared from a range.
    public static func canonicalCIDR(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), !pieces[0].isEmpty else { return nil }

        let addressText = String(pieces[0])
        if var address = canonicalAddress(addressText, family: AF_INET) {
            let prefix = pieces.count == 2 ? Int(pieces[1]) : 32
            guard let prefix, (0...32).contains(prefix) else { return nil }
            address.clearHostBits(prefixLength: prefix)
            guard let formatted = formatAddress(address.bytes, family: AF_INET) else { return nil }
            return "\(formatted)/\(prefix)"
        }

        if var address = canonicalAddress(addressText, family: AF_INET6) {
            let prefix = pieces.count == 2 ? Int(pieces[1]) : 128
            guard let prefix, (0...128).contains(prefix) else { return nil }
            address.clearHostBits(prefixLength: prefix)
            guard let formatted = formatAddress(address.bytes, family: AF_INET6) else { return nil }
            return "\(formatted)/\(prefix)"
        }

        return nil
    }

    private static func isHostName(_ value: String) -> Bool {
        guard value.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            return label.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }

    private static func canonicalAddress(_ raw: String, family: Int32) -> AddressBytes? {
        var address = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        let parsed = address.withUnsafeMutableBytes { buffer in
            raw.withCString { inet_pton(family, $0, buffer.baseAddress) }
        }
        guard parsed == 1 else { return nil }
        return AddressBytes(bytes: address)
    }

    private static func formatAddress(_ bytes: [UInt8], family: Int32) -> String? {
        var address = bytes
        var buffer = [CChar](repeating: 0, count: family == AF_INET ? Int(INET_ADDRSTRLEN) : Int(INET6_ADDRSTRLEN))
        let result = address.withUnsafeMutableBytes { raw in
            inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard result != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private struct AddressBytes {
        var bytes: [UInt8]

        mutating func clearHostBits(prefixLength: Int) {
            let fullBytes = prefixLength / 8
            let remainder = prefixLength % 8
            guard fullBytes < bytes.count else { return }
            if remainder != 0 {
                bytes[fullBytes] &= UInt8(0xff << (8 - remainder) & 0xff)
            }
            let firstZeroByte = remainder == 0 ? fullBytes : fullBytes + 1
            for index in firstZeroByte..<bytes.count {
                bytes[index] = 0
            }
        }
    }
}

public enum CloudNetworkPolicyEditError: Error, Equatable, LocalizedError, Sendable {
    case invalidDomain(String)
    case duplicateDomain(String)
    case tooManyDomains
    case invalidRange(String)
    case invalidPort
    case duplicateRange(String)
    case tooManyRanges
    case noteTooLong

    public var errorDescription: String? {
        switch self {
        case .invalidDomain(let value):
            return String(format: String(localized: "mobile.cloud.network.error.domain", defaultValue: "%@ is not a valid host name."), value)
        case .duplicateDomain(let value):
            return String(format: String(localized: "mobile.cloud.network.error.duplicateDomain", defaultValue: "%@ is already listed."), value)
        case .tooManyDomains:
            return String(localized: "mobile.cloud.network.error.tooManyDomains", defaultValue: "The domain list is full.")
        case .invalidRange(let value):
            return String(format: String(localized: "mobile.cloud.network.error.range", defaultValue: "%@ is not an IP range."), value)
        case .invalidPort:
            return String(localized: "mobile.cloud.network.error.port", defaultValue: "The port must be between 1 and 65535.")
        case .duplicateRange(let value):
            return String(format: String(localized: "mobile.cloud.network.error.duplicateRange", defaultValue: "%@ is already listed."), value)
        case .tooManyRanges:
            return String(localized: "mobile.cloud.network.error.tooManyRanges", defaultValue: "The IP range list is full.")
        case .noteTooLong:
            return String(localized: "mobile.cloud.network.error.note", defaultValue: "The note is too long.")
        }
    }
}
