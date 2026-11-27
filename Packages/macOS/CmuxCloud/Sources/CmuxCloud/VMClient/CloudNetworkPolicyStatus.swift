import Foundation

/// A quick-add group of exact domains (`NETWORK_POLICY_PRESETS` on the server).
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

/// `GET /api/vm/network-presets`: the catalog the New Machine sheet edits against.
public struct CloudNetworkPresetCatalog: Codable, Equatable, Sendable {
    public let presets: [CloudNetworkPreset]
    public let requiredDomains: [String]
    public let defaultPolicy: CloudNetworkPolicy
    /// The hosts coding-agent updates reach (`GUEST_AGENT_UPDATE_DOMAINS`).
    /// A server that predates the field updated agents through npm, so its
    /// catalog means the npm registry.
    public let agentUpdateDomains: [String]

    /// What an older server's agent updates needed.
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presets = try container.decodeIfPresent([CloudNetworkPreset].self, forKey: .presets) ?? []
        requiredDomains = try container.decodeIfPresent([String].self, forKey: .requiredDomains) ?? []
        defaultPolicy = try container.decodeIfPresent(CloudNetworkPolicy.self, forKey: .defaultPolicy) ?? .default
        agentUpdateDomains = try container.decodeIfPresent([String].self, forKey: .agentUpdateDomains) ?? Self.legacyAgentUpdateDomains
    }
}

/// Whether the provider's rules match the stored policy yet.
public struct CloudNetworkApplied: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case applied, pending, failed
    }

    public let state: State
    public let error: String?
    /// ISO 8601, as sent by the server.
    public let appliedAt: String?

    public init(state: State, error: String? = nil, appliedAt: String? = nil) {
        self.state = state
        self.error = error
        self.appliedAt = appliedAt
    }

    public var title: String {
        switch state {
        case .applied: return String(localized: "cloud.network.applied.applied", defaultValue: "Applied")
        case .pending: return String(localized: "cloud.network.applied.pending", defaultValue: "Applying…")
        case .failed: return String(localized: "cloud.network.applied.failed", defaultValue: "Could not apply")
        }
    }
}

/// `GET` and `PUT /api/vm/{id}/network`.
public struct CloudNetworkPolicyStatus: Codable, Equatable, Sendable {
    public let policy: CloudNetworkPolicy
    public let presets: [CloudNetworkPreset]
    public let requiredDomains: [String]
    public let applied: CloudNetworkApplied?
    /// See `CloudNetworkPresetCatalog.agentUpdateDomains`.
    public let agentUpdateDomains: [String]

    public init(
        policy: CloudNetworkPolicy,
        presets: [CloudNetworkPreset],
        requiredDomains: [String],
        applied: CloudNetworkApplied?,
        agentUpdateDomains: [String] = CloudNetworkPresetCatalog.legacyAgentUpdateDomains
    ) {
        self.policy = policy
        self.presets = presets
        self.requiredDomains = requiredDomains
        self.applied = applied
        self.agentUpdateDomains = agentUpdateDomains
    }

    private enum CodingKeys: String, CodingKey {
        case policy, presets, requiredDomains, applied, agentUpdateDomains
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decodeIfPresent(CloudNetworkPolicy.self, forKey: .policy) ?? .default
        presets = try container.decodeIfPresent([CloudNetworkPreset].self, forKey: .presets) ?? []
        requiredDomains = try container.decodeIfPresent([String].self, forKey: .requiredDomains) ?? []
        applied = try container.decodeIfPresent(CloudNetworkApplied.self, forKey: .applied)
        agentUpdateDomains = try container.decodeIfPresent([String].self, forKey: .agentUpdateDomains)
            ?? CloudNetworkPresetCatalog.legacyAgentUpdateDomains
    }

    public var catalog: CloudNetworkPresetCatalog {
        CloudNetworkPresetCatalog(presets: presets, requiredDomains: requiredDomains, agentUpdateDomains: agentUpdateDomains)
    }

    /// The socket and `--json` payload: exactly the server's shape.
    public var foundationObject: [String: Any] {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

/// The server's refusal of a policy change, decoded from its JSON body.
public enum CloudNetworkPolicyRequestError: Error, Equatable, LocalizedError {
    /// 400 `{error: "invalid_network_policy", path, message}`.
    case invalid(path: String?, message: String)
    /// 501 `{error: "vm_operation_unsupported"}`: this machine's provider has no egress control.
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .invalid(let path, let message):
            guard let path, !path.isEmpty else { return message }
            return "\(path): \(message)"
        case .unsupported:
            return String(
                localized: "cloud.network.error.unsupported",
                defaultValue: "This machine's provider does not support outbound network rules."
            )
        }
    }

    /// Maps an HTTP error body to a typed refusal; nil for other failures.
    public static func from(status: Int, body: String) -> Self? {
        let object = body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let code = object?["error"] as? String
        if status == 501, code == "vm_operation_unsupported" { return .unsupported }
        guard status == 400, let object else { return nil }
        let message = (object["message"] as? String) ?? code ?? body
        return .invalid(path: object["path"] as? String, message: message)
    }
}
