import CmuxNextAgentCursor

extension AppServices {
    /// The visibility source with its change consumer: a tracked target that
    /// moves between input events (column scroll, minimize, tab or workspace
    /// switch) re-places the cursors of every content that follows it.
    func makeAgentCursorVisibility() -> AgentCursorVisibilitySource {
        let source = AgentCursorVisibilitySource(services: self)
        source.onChange = { [weak self] target, _ in self?.agentCursorPlacementsDidChange(target: target) }
        return source
    }

    /// Every workspace content of every window (shown and parked) re-places
    /// the cursors whose last input went to `target`; a content whose window
    /// does not show it resolves the target elsewhere and hides them.
    func agentCursorPlacementsDidChange(target: String) {
        for controller in windows.controllers {
            controller.content?.agentCursor?.model.placementsDidChange(target: target)
            for parked in controller.parked {
                parked.agentCursor?.model.placementsDidChange(target: target)
            }
        }
    }
}
