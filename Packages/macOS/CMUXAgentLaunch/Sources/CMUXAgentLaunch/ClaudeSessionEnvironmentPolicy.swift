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

    /// Creates the canonical Claude session-environment policy.
    public init() {
        inheritedSessionIdentityKeys = [
            "CLAUDECODE",
            "CLAUDE_CODE",
            "CLAUDE_CODE_CHILD_SESSION",
            "CLAUDE_CODE_BRIDGE_SESSION_ID",
            "CLAUDE_CODE_PARENT_SESSION_ID",
            "CLAUDE_CODE_SESSION_ID",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_EXECPATH",
            "CLAUDE_CODE_SSE_PORT",
        ]
        inheritedTrustBypassKeys = [
            "CLAUDE_CODE_SANDBOXED",
            "CMUX_CLAUDE_TEAMS_SANDBOXED",
        ]
    }
}
