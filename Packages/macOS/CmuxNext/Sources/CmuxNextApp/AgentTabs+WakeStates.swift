import CmuxNextAgentPane

extension AgentTabStore {
    /// What every chat page holds that acpmux does not, by tab, for the next launch.
    func relaunchWakeStates(limit: Duration = .seconds(1)) async -> [String: AgentPaneWakeState] {
        [:]
    }

    /// Hands the last quit's states to the tabs' first pages (``AgentPaneWakeStateFile``).
    func restoreWakeStates() {}
}
