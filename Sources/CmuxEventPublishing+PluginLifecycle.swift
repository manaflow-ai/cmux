import CMUXAgentLaunch

extension CmuxEventBus {
    /// Projects received lifecycle hooks onto the plugin event vocabulary.
    func publishPluginLifecycleProjection(
        _ event: WorkstreamEvent,
        payload: [String: Any]
    ) {
        let lifecycleName: String?
        switch event.hookEventName {
        case .sessionStart:
            lifecycleName = "agent.session.started"
        case .sessionEnd:
            lifecycleName = "agent.session.ended"
        case .userPromptSubmit, .postToolUse, .stop:
            lifecycleName = "agent.session.state_changed"
        default:
            lifecycleName = nil
        }
        guard let lifecycleName else { return }
        publish(
            name: lifecycleName,
            category: "agent",
            source: event.source,
            workspaceId: event.workspaceId,
            surfaceId: event.surfaceId,
            payload: payload
        )
    }
}
