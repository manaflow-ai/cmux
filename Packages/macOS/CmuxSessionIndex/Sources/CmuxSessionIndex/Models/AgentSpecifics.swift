public import CMUXAgentLaunch

/// Agent-specific fields used to build the resume command with appropriate flags.
public enum AgentSpecifics: Hashable {
    case claude(model: String?, permissionMode: String?, configDirectoryForResume: String?)
    case codex(model: String?, approvalPolicy: String?, sandboxMode: String?, effort: String?)
    case grok(model: String?, permissionMode: String?, sandboxMode: String?, grokHome: String?)
    case opencode(providerModel: String?, agentName: String?)
    case rovodev
    case hermesAgent(source: String?, model: String?, hermesHome: String?)
    case registered(CmuxVaultAgentRegistration)
}
