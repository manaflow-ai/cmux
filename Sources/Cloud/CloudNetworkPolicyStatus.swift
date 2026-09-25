import Foundation

/// A quick-add group of exact domains (`NETWORK_POLICY_PRESETS` on the server).
struct CloudNetworkPreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let domains: [String]
}

/// `GET /api/vm/network-presets`: the catalog the New Machine sheet edits against.
struct CloudNetworkPresetCatalog: Codable, Equatable, Sendable {
    let presets: [CloudNetworkPreset]
    let requiredDomains: [String]
    let defaultPolicy: CloudNetworkPolicy

    private enum CodingKeys: String, CodingKey {
        case presets, requiredDomains, defaultPolicy
    }

    init(presets: [CloudNetworkPreset], requiredDomains: [String], defaultPolicy: CloudNetworkPolicy = .default) {
        self.presets = presets
        self.requiredDomains = requiredDomains
        self.defaultPolicy = defaultPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presets = try container.decodeIfPresent([CloudNetworkPreset].self, forKey: .presets) ?? []
        requiredDomains = try container.decodeIfPresent([String].self, forKey: .requiredDomains) ?? []
        defaultPolicy = try container.decodeIfPresent(CloudNetworkPolicy.self, forKey: .defaultPolicy) ?? .default
    }
}

/// Whether the provider's rules match the stored policy yet.
struct CloudNetworkApplied: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case applied, pending, failed
    }

    let state: State
    let error: String?
    /// ISO 8601, as sent by the server.
    let appliedAt: String?

    init(state: State, error: String? = nil, appliedAt: String? = nil) {
        self.state = state
        self.error = error
        self.appliedAt = appliedAt
    }

    var title: String {
        switch state {
        case .applied: return String(localized: "cloud.network.applied.applied", defaultValue: "Applied")
        case .pending: return String(localized: "cloud.network.applied.pending", defaultValue: "Applying…")
        case .failed: return String(localized: "cloud.network.applied.failed", defaultValue: "Could not apply")
        }
    }
}

/// `GET` and `PUT /api/vm/{id}/network`.
struct CloudNetworkPolicyStatus: Codable, Equatable, Sendable {
    let policy: CloudNetworkPolicy
    let presets: [CloudNetworkPreset]
    let requiredDomains: [String]
    let applied: CloudNetworkApplied?

    init(policy: CloudNetworkPolicy, presets: [CloudNetworkPreset], requiredDomains: [String], applied: CloudNetworkApplied?) {
        self.policy = policy
        self.presets = presets
        self.requiredDomains = requiredDomains
        self.applied = applied
    }

    private enum CodingKeys: String, CodingKey {
        case policy, presets, requiredDomains, applied
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decodeIfPresent(CloudNetworkPolicy.self, forKey: .policy) ?? .default
        presets = try container.decodeIfPresent([CloudNetworkPreset].self, forKey: .presets) ?? []
        requiredDomains = try container.decodeIfPresent([String].self, forKey: .requiredDomains) ?? []
        applied = try container.decodeIfPresent(CloudNetworkApplied.self, forKey: .applied)
    }

    var catalog: CloudNetworkPresetCatalog {
        CloudNetworkPresetCatalog(presets: presets, requiredDomains: requiredDomains)
    }

    /// The socket and `--json` payload: exactly the server's shape.
    var foundationObject: [String: Any] {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

/// The server's refusal of a policy change, decoded from its JSON body.
enum CloudNetworkPolicyRequestError: Error, Equatable, LocalizedError {
    /// 400 `{error: "invalid_network_policy", path, message}`.
    case invalid(path: String?, message: String)
    /// 501 `{error: "vm_operation_unsupported"}`: this machine's provider has no egress control.
    case unsupported

    var errorDescription: String? {
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
    static func from(status: Int, body: String) -> Self? {
        let object = body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let code = object?["error"] as? String
        if status == 501, code == "vm_operation_unsupported" { return .unsupported }
        guard status == 400, let object else { return nil }
        let message = (object["message"] as? String) ?? code ?? body
        return .invalid(path: object["path"] as? String, message: message)
    }
}
