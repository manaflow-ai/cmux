import CmuxNextAgentCursor

/// App wiring of agent cursors that is not part of `AppServices` itself.
enum AgentCursorWiring {
    /// The visibility source with its change consumer: a tracked target that
    /// moves between input events (column scroll, minimize, tab or workspace
    /// switch) re-places the cursors of every content that follows it.
    static func makeVisibility(services: AppServices) -> AgentCursorVisibilitySource {
        let source = AgentCursorVisibilitySource(services: services)
        source.onChange = { [weak services] target, _ in
            guard let services else { return }
            placementsDidChange(target: target, in: services)
        }
        return source
    }

    /// Every workspace content of every window (shown and parked) re-places
    /// the cursors whose last input went to `target`; a content whose window
    /// does not show it resolves the target elsewhere and hides them.
    static func placementsDidChange(target: String, in services: AppServices) {
        for controller in services.windows.controllers {
            controller.content?.agentCursor?.model.placementsDidChange(target: target)
            for parked in controller.parked {
                parked.agentCursor?.model.placementsDidChange(target: target)
            }
        }
    }
}
