import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import WebKit

/// Copy Last Code Block (Opt-Cmd-;) and Archive Chat (Ctrl-Cmd-A), as in the Codex app (cx-ncc.72):
/// the focused agent chat's page copies its latest answer's last code block, or archives the chat
/// the way its menu's Archive does.
enum AgentChatKeyHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        AgentChatCopyHandlers.bind(into: registry, context: context)
        registry.bind("agentPane.copyLastCodeBlock", run: { invocation in
            guard let view = chatView(context, invocation, refusal: MiscHandlerStrings.copyCodeNeedsAgentChat) else { return }
            let registry = context.registry
            let interactive = !registry.isCapturingRefusal
            let services = context.services
            let work: ActionWork = Task {
                let script = "return window.cmuxAcpmuxBridge?.lastCodeBlock?.() ?? null;"
                let reason: String
                do {
                    let answer = try await view.callPageScript(script)
                    if let code = answer as? String, !code.isEmpty {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(code, forType: .string) { return nil }
                        reason = MiscHandlerStrings.copyCodeFailed
                    } else {
                        reason = MiscHandlerStrings.noCodeBlock
                    }
                } catch {
                    reason = MiscHandlerStrings.copyCodeFailed
                }
                // A key press or menu run sees why; a caller (palette, CLI) gets the reason.
                if interactive { services.refusalHUD.show(reason, in: view.window ?? services.windows.active?.window) }
                return ActionWorkFailure(refusal: .unavailable, reason: reason)
            }
            registry.track(work)
        })
        // A Priority row's chat (`agent-chat:`) archives from the row, while the Priority view is on;
        // else the focused chat's Archive, whatever the view's setting.
        SidebarPriorityRowActions(chats: .app, unavailable: SidebarPriorityRowActions.viewOff(context))
            .bindArchive(into: registry) { invocation in
                chatView(context, invocation, refusal: MiscHandlerStrings.archiveChatNeedsAgentChat)?.archiveChat()
            }
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
