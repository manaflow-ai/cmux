import Foundation

public nonisolated struct TaskAgent: Codable, Sendable, Hashable {
    public var principal: String
    public var harness: String
    public var onBehalfOf: String

    enum CodingKeys: String, CodingKey {
        case principal, harness
        case onBehalfOf = "on_behalf_of"
    }

    public init(principal: String, harness: String, onBehalfOf: String) {
        self.principal = principal
        self.harness = harness
        self.onBehalfOf = onBehalfOf
    }
}

/// `{kind: user, id}` or `{kind: agent, principal, harness, …}`.
public nonisolated struct TaskPrincipal: Codable, Sendable, Hashable {
    public var kind: String
    public var id: String?
    public var principal: String?
    public var harness: String?

    public init(user: String) {
        kind = "user"
        id = user
    }

    /// `usr_…` or `agt_…`.
    public var stableID: String { id ?? principal ?? "" }

    /// Short display name: the part after the prefix.
    public var shortName: String {
        let raw = stableID
        if let range = raw.range(of: "_") { return String(raw[range.upperBound...]) }
        return raw
    }
}
