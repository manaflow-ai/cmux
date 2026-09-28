import CmuxTerminalCore

extension TerminalPanel {
    /// A click on an agent key hint, resolved before it is pressed.
    struct AgentKeyHintClick: Equatable {
        var hint: AgentKeyHint
        var agent: AgentKeyHintDetector.Agent
        var lifecycle: AgentHibernationLifecycleState
        var policy: AgentKeyHintClickPolicy
    }
}
