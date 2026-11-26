internal import CMUXAgentLaunch

extension TerminalSurface {
    /// The stable teammate title encoded in this surface's launch commands.
    public var agentPanelTitle: String? {
        AgentPanelTitleResolver().title(fromCommands: [
            tmuxStartCommand,
            initialCommand,
        ].compactMap { $0 })
    }
}
