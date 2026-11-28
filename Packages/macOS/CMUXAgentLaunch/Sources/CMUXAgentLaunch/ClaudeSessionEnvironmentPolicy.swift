/// Identifies inherited Claude runtime state that must not cross an independent launch boundary.
public struct ClaudeSessionEnvironmentPolicy: Sendable {
    /// Environment keys that bind a Claude process to an existing parent, child, or bridge session.
    public let inheritedSessionIdentityKeys: Set<String>

    /// Environment keys that carry a previous launch's explicit trust-bypass decision.
    public let inheritedTrustBypassKeys: Set<String>

    /// All inherited Claude runtime state that an independent launch must remove.
    public var inheritedIndependentLaunchKeys: Set<String> {
        inheritedSessionIdentityKeys.union(inheritedTrustBypassKeys)
    }
}
