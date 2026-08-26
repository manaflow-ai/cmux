/// Provenance and overwrite authority for a virtual-node title.
public enum NestedTitleAuthority: String, Codable, Equatable, Sendable {
    /// Best-effort title inferred from prompts, environment, or other hints.
    case inferred

    /// Title emitted by the provider topology protocol.
    case provider

    /// Title locked by a cmux host-surface policy.
    case host

    /// Explicit user-owned title.
    case user

    var precedence: Int {
        switch self {
        case .inferred: 0
        case .provider: 1
        case .host: 2
        case .user: 3
        }
    }

    /// Whether an absent provider title may remove a title with this authority.
    var canBeClearedByProvider: Bool {
        switch self {
        case .inferred, .provider: true
        case .host, .user: false
        }
    }
}
