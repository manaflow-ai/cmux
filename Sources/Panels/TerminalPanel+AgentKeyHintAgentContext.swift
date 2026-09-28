import CmuxTerminalCore

extension TerminalPanel {
    /// Agent identity and exact lifecycle that authorized a hint click.
    struct AgentKeyHintAgentContext {
        var agent: AgentKeyHintDetector.Agent
        var lifecycle: AgentHibernationLifecycleState
    }
}
