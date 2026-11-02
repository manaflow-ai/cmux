public import Foundation

/// A Cloud machine's outbound network policy, as `GET /api/vm/{id}/network` reports it
/// (web/services/vms/networkPolicy.ts). The lists stay stored whatever the mode, so switching
/// modes and back restores them; the server always adds the hosts cmux itself needs.
public struct CloudNetworkPolicy: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Hashable, Codable {
        /// Every public address (a machine with no stored policy).
        case full
        /// The listed ranges, domains and presets, plus cmux's own hosts.
        case allowlist
        /// cmux's own hosts only.
        case none
    }

    /// One allowed IP range, kept exactly as stored.
    public struct Range: Sendable, Hashable, Codable {
        public var cidr: String
        public var port: Int?
        public var `protocol`: String?
        public var note: String?

        var body: [String: any Sendable] {
            var body: [String: any Sendable] = ["cidr": cidr]
            if let port { body["port"] = port }
            if let `protocol` { body["protocol"] = `protocol` }
            if let note { body["note"] = note }
            return body
        }
    }

    public var mode: Mode
    public var ranges: [Range]
    public var domains: [String]
    public var presets: [String]
    public var allowDns: Bool

    public init(mode: Mode, ranges: [Range] = [], domains: [String] = [], presets: [String] = [], allowDns: Bool = true) {
        self.mode = mode
        self.ranges = ranges
        self.domains = domains
        self.presets = presets
        self.allowDns = allowDns
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        ranges = try container.decodeIfPresent([Range].self, forKey: .ranges) ?? []
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
        presets = try container.decodeIfPresent([String].self, forKey: .presets) ?? []
        allowDns = try container.decodeIfPresent(Bool.self, forKey: .allowDns) ?? true
    }

    /// The `PUT /api/vm/{id}/network` body.
    var body: [String: any Sendable] {
        ["mode": mode.rawValue, "ranges": ranges.map(\.body), "domains": domains, "presets": presets, "allowDns": allowDns]
    }
}

/// The answer of `GET` and `PUT /api/vm/{id}/network`: the policy, the preset catalog the
/// server serves (so a preset change needs no client update) and whether the provider applied it.
public struct CloudNetworkPolicyState: Sendable, Hashable, Decodable {
    public struct Preset: Sendable, Hashable, Decodable {
        public var id: String
        public var label: String
    }

    public struct Applied: Sendable, Hashable, Decodable {
        /// `applied`, `pending` or `failed`.
        public var state: String
        /// The server's localized reason for a failed apply.
        public var error: String?
    }

    public var policy: CloudNetworkPolicy
    public var presets: [Preset]
    public var applied: Applied?

    public init(policy: CloudNetworkPolicy, presets: [Preset], applied: Applied? = nil) {
        self.policy = policy
        self.presets = presets
        self.applied = applied
    }
}

/// The three internet access levels a person picks for a machine (Internet Access…). `trusted`
/// is the allowlist of every preset the server serves: GitHub, the package registries and the
/// model providers. Each keeps the machine's own ranges and domains as they are.
public enum CloudNetworkAccess: String, CaseIterable, Sendable, Hashable {
    case full, trusted
    /// cmux's own hosts only (`none` on the CLI and the server).
    case noInternet = "none"

    /// How much each opens, for ``widens(from:to:)``.
    private static func rank(_ mode: CloudNetworkPolicy.Mode) -> Int {
        switch mode {
        case .none: 0
        case .allowlist: 1
        case .full: 2
        }
    }

    /// `current` changed to this level. `presets` is the server's catalog. A restricted level drops
    /// any portless whole-Internet range (`0.0.0.0/0`, `::/0`): the server opens all public egress
    /// for one whatever the mode (web/services/vms/networkPolicy.ts `compileNetworkPolicy`).
    public func applied(to current: CloudNetworkPolicy, presets: [String]) -> CloudNetworkPolicy {
        var policy = current
        switch self {
        case .full: policy.mode = .full
        case .noInternet: policy.mode = .none
        case .trusted:
            policy.mode = .allowlist
            policy.presets += presets.filter { !current.presets.contains($0) }
        }
        if self != .full { policy.ranges.removeAll(where: Self.opensTheWholeInternet) }
        return policy
    }

    /// A range the server reads as the whole public Internet, in any mode.
    static func opensTheWholeInternet(_ range: CloudNetworkPolicy.Range) -> Bool {
        range.port == nil && (range.cidr == "0.0.0.0/0" || range.cidr == "::/0")
    }

    /// The level `policy` reads as, or nil for an allowlist a person built by hand (custom).
    public static func level(of policy: CloudNetworkPolicy, presets: [String]) -> CloudNetworkAccess? {
        switch policy.mode {
        case .full: .full
        case .none: .noInternet
        case .allowlist:
            Set(presets).isSubset(of: Set(policy.presets)) && policy.ranges.isEmpty && policy.domains.isEmpty ? .trusted : nil
        }
    }

    /// Whether going from `old` to `new` lets the machine reach anything it could not before: a
    /// more open mode, or an allowlist that gained a preset. The lists are kept on every change.
    public static func widens(from old: CloudNetworkPolicy, to new: CloudNetworkPolicy) -> Bool {
        if rank(new.mode) != rank(old.mode) { return rank(new.mode) > rank(old.mode) }
        return new.mode == .allowlist && !Set(new.presets).isSubset(of: Set(old.presets))
    }
}

extension CloudAPIClient {
    /// `GET /api/vm/{id}/network`: the machine's outbound policy and whether it is applied.
    public func networkPolicy(_ id: String) async throws -> CloudNetworkPolicyState {
        try await send("GET", "/api/vm/\(id)/network", timeout: .seconds(30), as: CloudNetworkPolicyState.self)
    }

    /// `PUT /api/vm/{id}/network`: replaces the policy. The server applies it live on a running or
    /// paused machine, with no restart, and its answer says whether the provider took it.
    public func setNetworkPolicy(_ id: String, _ policy: CloudNetworkPolicy) async throws -> CloudNetworkPolicyState {
        try await send("PUT", "/api/vm/\(id)/network", body: policy.body, timeout: .seconds(60), as: CloudNetworkPolicyState.self)
    }
}
