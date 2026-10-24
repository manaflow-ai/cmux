import CmuxNextAgentPane
import CmuxNextDesign

extension AppServices {
    /// Repaints every window when a setting changes that moves no theme color but every window
    /// draws: `appearance.borders`, calm mode, the terminal face (``WindowDrawnSettings``) and the
    /// agent page settings pushed with the theme (``AgentPageSettings``), so borders set outside
    /// layout and open agent pages follow at once (plans/cmux-next/borders.md).
    func observeWindowRepaints() {
        windowRepaintObservation?.cancel()
        windowRepaintObservation = Self.followWindowRepaints(design: DesignSettings.shared, store: themeStore)
    }

    /// The observation ``observeWindowRepaints()`` keeps, for `design` and `store` (tests pass their own).
    static func followWindowRepaints(design: DesignSettings, store: ThemeStore) -> Task<Void, Never> {
        store.repaintAll(following: { [weak design] in
            design.map { WindowRepaintInputs(window: $0.windowDrawn, agentPage: AgentPageSettings()) }
        })
    }
}

/// What ``AppServices/followWindowRepaints(design:store:)`` follows.
private nonisolated struct WindowRepaintInputs: Equatable, Sendable {
    var window: WindowDrawnSettings
    var agentPage: AgentPageSettings
}
