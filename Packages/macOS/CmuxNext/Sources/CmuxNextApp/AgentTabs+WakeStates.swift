import CmuxNextAgentPane

extension AgentTabStore {
    /// What every chat page holds that acpmux does not, by tab, for the next launch: each live page
    /// that finished its handshake is asked at once (within `limit`), and released pages' kept
    /// states (``AgentPageHibernation``) fill in the rest. A page that does not answer in time keeps
    /// nothing.
    func relaunchWakeStates(limit: Duration = .seconds(1)) async -> [String: AgentPaneWakeState] {
        var states = wakeStates
        let read = wakeStateReader
        // task-owner: every ask is awaited below, before the quit goes on.
        let asks = views.filter { $0.value.model.hasHandshake }.map { key, view in
            (key, Task { await read(view, limit) })
        }
        for (key, ask) in asks {
            states[resolve(key)] = await ask.value
        }
        return states.filter { !$0.value.isEmpty }
    }

    /// Hands the last quit's states to the tabs' first pages (``AgentPaneWakeStateFile``); a state
    /// this run already holds stands.
    func restoreWakeStates() {
        wakeStates.merge(wakeStateFile.take()) { current, _ in current }
    }
}
