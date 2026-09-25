import Foundation

/// Outbound network policy of one Cloud machine, the wire shape of
/// `web/services/vms/networkPolicy.ts`. The control plane owns validation and
/// canonical form; this type mirrors enough of it to edit locally and to
/// reject obvious mistakes before a round trip.
struct CloudNetworkPolicy: Codable, Equatable, Sendable {
    static let currentVersion = 1

    /// Server limits (`NETWORK_POLICY_LIMITS`).
    static let maxRanges = 64
    static let maxDomains = 128
    static let maxNoteLength = 120

    /// What a machine without a stored policy has: the whole Internet.
    static let `default` = CloudNetworkPolicy(mode: .full)

    var version: Int
    var mode: CloudNetworkPolicyMode
    var ranges: [CloudNetworkRange]
    /// Exact lowercase host names, HTTPS only.
    var domains: [String]
    /// Preset ids; the server expands them so a preset update reaches every machine.
    var presets: [String]
    /// Allowlist mode only: open DNS to the guest's resolvers. Open DNS is
    /// itself an outbound channel.
    var allowDns: Bool

    init(
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

    /// Tolerates omitted collections and `allowDns` the same way the server's
    /// `parseNetworkPolicy` does.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        mode = try container.decode(CloudNetworkPolicyMode.self, forKey: .mode)
        ranges = try container.decodeIfPresent([CloudNetworkRange].self, forKey: .ranges) ?? []
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
        presets = try container.decodeIfPresent([String].self, forKey: .presets) ?? []
        allowDns = try container.decodeIfPresent(Bool.self, forKey: .allowDns) ?? true
    }

    /// The JSON object sent as a request body or a socket param.
    var foundationObject: [String: Any] {
        [
            "version": version,
            "mode": mode.rawValue,
            "ranges": ranges.map(\.foundationObject),
            "domains": domains,
            "presets": presets,
            "allowDns": allowDns,
        ]
    }

    /// Decodes a Foundation JSON object (socket params, `JSONSerialization` output).
    init(foundationObject: Any) throws {
        // `data(withJSONObject:)` raises an Objective-C exception on a non-container.
        guard foundationObject is [String: Any], JSONSerialization.isValidJSONObject(foundationObject) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "network policy must be a JSON object"))
        }
        let data = try JSONSerialization.data(withJSONObject: foundationObject)
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    /// Compact JSON with sorted keys, for CLI arguments and idempotency scopes.
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

enum CloudNetworkPolicyMode: String, Codable, CaseIterable, Sendable {
    case full
    case allowlist
    case none

    var title: String {
        switch self {
        case .full: return String(localized: "cloud.network.mode.full", defaultValue: "Full internet")
        case .allowlist: return String(localized: "cloud.network.mode.allowlist", defaultValue: "Allowlist")
        case .none: return String(localized: "cloud.network.mode.none", defaultValue: "No internet")
        }
    }

    var explanation: String {
        switch self {
        case .full:
            return String(localized: "cloud.network.mode.full.detail", defaultValue: "The machine can reach any public address.")
        case .allowlist:
            return String(localized: "cloud.network.mode.allowlist.detail", defaultValue: "Only the domains and IP ranges you list, plus what cmux needs.")
        case .none:
            return String(localized: "cloud.network.mode.none.detail", defaultValue: "No outbound access except what cmux itself needs.")
        }
    }
}

enum CloudNetworkRangeProtocol: String, Codable, CaseIterable, Sendable {
    case tcp
    case udp
}

/// One allowed IP range, optionally narrowed to one port and protocol.
struct CloudNetworkRange: Codable, Equatable, Hashable, Sendable {
    /// `network/prefix`, IPv4 or IPv6. The server stores the canonical form.
    var cidr: String
    /// 1–65535. Requires ``transport``. Absent: every port and protocol.
    var port: Int?
    var transport: CloudNetworkRangeProtocol?
    var note: String?

    init(cidr: String, port: Int? = nil, transport: CloudNetworkRangeProtocol? = nil, note: String? = nil) {
        self.cidr = cidr
        self.port = port
        self.transport = transport
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case cidr, port, note
        case transport = "protocol"
    }

    /// Two entries with the same key are the same rule (the server dedupes on it).
    var identityKey: String {
        "\(cidr)|\(port.map(String.init) ?? "")|\(transport?.rawValue ?? "")"
    }

    /// "10.0.0.0/8", "10.0.0.0/8 tcp/5432".
    var displayText: String {
        guard let port else { return cidr }
        return "\(cidr) \(transport?.rawValue ?? CloudNetworkRangeProtocol.tcp.rawValue)/\(port)"
    }

    var foundationObject: [String: Any] {
        var object: [String: Any] = ["cidr": cidr]
        if let port { object["port"] = port }
        if let transport { object["protocol"] = transport.rawValue }
        if let note, !note.isEmpty { object["note"] = note }
        return object
    }
}
