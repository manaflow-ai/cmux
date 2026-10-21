import CmuxNextAgentPane

extension AgentTabStore {
    /// What every chat page holds that acpmux does not, by tab, for the next launch: each live page
    /// that finished its handshake is asked at once (within `limit`); a page still loading keeps
    /// the state it was built with, and released pages' kept states (``AgentPageHibernation``) fill
    /// in the rest. A page that does not answer in time keeps nothing; a tab gone from every tree
    /// keeps nothing.
    func relaunchWakeStates(limit: Duration = .seconds(1)) async -> [String: AgentPaneWakeState] {
        var states = wakeStates
        let read = wakeStateReader
        for (key, view) in views where !view.model.hasHandshake {
            if let pending = view.model.pendingWake { states[resolve(key)] = pending }
        }
        // task-owner: every ask is awaited below, before the quit goes on.
        let asks = views.filter { $0.value.model.hasHandshake }.map { key, view in
            (key, Task { await read(view, limit) })
        }
        for (key, ask) in asks {
            states[resolve(key)] = await ask.value
        }
        return states.filter { key, state in !state.isEmpty && lookup(key) != nil }
    }

    /// Hands the last quit's states to the tabs' first pages (``AgentPaneWakeStateFile``); a state
    /// this run already holds stands.
    func restoreWakeStates() {
        wakeStates.merge(wakeStateFile.take()) { current, _ in current }
    }
}
