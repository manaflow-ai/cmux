import CmuxNextActions
import CmuxNextAgentPane

/// Tile Subagents (AgentSubagentActionCatalog): asks the focused chat's page to tile its running
/// subagents. The page knows them; it opens each with `chat.subagentPane {tile: true}`
/// (SubagentBeside), as its Subagents card's Tile button does.
enum AgentSubagentTileHandler {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agentChat.tileSubagents", invoke: { invocation in
            let tabs = context.services.agentTabs
            guard let key = context.scope(invocation).pane?.currentTabKey, tabs.existingView(key) != nil else {
                return context.refuse(MiscHandlerStrings.noAgentPane)
            }
            tabs.revealTurn(AgentSubagentPanes.tileReveal, in: key)
        })
    }
}
