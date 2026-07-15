/// A durable browser association key plus any prior keys that may need migration.
public struct BrowserWorkspaceIdentity: Equatable, Sendable, ExpressibleByStringLiteral {
    /// The stable key used to associate persisted browser state with a workspace.
    public let rawValue: String
    /// Prior keys that can be migrated to ``rawValue`` during reconciliation.
    public let aliases: Set<String>

    /// Creates a durable browser workspace identity.
    /// - Parameters:
    ///   - rawValue: The stable persistence key.
    ///   - aliases: Prior persistence keys that can be migrated to `rawValue`.
    public init(rawValue: String, aliases: Set<String> = []) {
        self.rawValue = rawValue
        self.aliases = aliases
    }

    /// Creates an identity from an already-durable string literal.
    /// - Parameter value: The stable persistence key.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}
