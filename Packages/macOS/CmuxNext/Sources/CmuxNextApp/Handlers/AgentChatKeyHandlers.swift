import CmuxNextActions
import CmuxNextAgentPane

/// Copy Last Code Block (Opt-Cmd-;) and Archive Chat (Ctrl-Cmd-A), as in the Codex app (cx-ncc.72):
/// the focused agent chat's page copies its latest answer's last code block, or archives the chat
/// the way its menu's Archive does.
enum AgentChatKeyHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agentPane.copyLastCodeBlock", run: { invocation in
            chatView(context, invocation, refusal: MiscHandlerStrings.copyCodeNeedsAgentChat)?.copyLastCodeBlock()
        })
        registry.bind("agentPane.archiveChat", run: { invocation in
            chatView(context, invocation, refusal: MiscHandlerStrings.archiveChatNeedsAgentChat)?.archiveChat()
        })
    }

    private static func chatView(_ context: AppActionContext, _ invocation: ActionInvocation, refusal: String) -> AgentPaneView? {
        guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
              let view = context.services.agentTabs.existingView(key) else {
            context.refuse(refusal)
            return nil
        }
        return view
    }
}
