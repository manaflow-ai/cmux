import CmuxNextActions

/// The agent GUI's actions: open its window, start a conversation, and
/// toggle keeping the Mac awake while a turn runs (``AgentService``).
enum AgentGUIHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let agents = context.services.agents
        let available: @MainActor () -> Bool = { agents.backend != nil }
        registry.bind("agentGUI.openWindow", isEnabled: available) {
            agents.showWindow()
        }
        registry.bind("agentGUI.newConversation", isEnabled: available) {
            agents.showWindow()?.newConversation()
        }
        registry.bind("agentGUI.toggleKeepAwake") {
            agents.keepAwakeDuringTurns.toggle()
        }
    }
}
