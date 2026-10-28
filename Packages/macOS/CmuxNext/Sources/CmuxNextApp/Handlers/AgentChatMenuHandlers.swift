import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// Native bindings for rows in an agent chat's header and "..." menu.
/// Every binding resolves the focused pane at run time, then calls the page or
/// host path used by the existing menu. This keeps a stale palette invocation
/// from acting on another chat after a session switch.
enum AgentChatMenuHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        bindPageCommands(into: registry, context: context)
        bindMarkUnread(into: registry, context: context)
        bindRevealCwd(into: registry, context: context)
    }

    private static func bindPageCommands(into registry: ActionRegistry, context: AppActionContext) {
        let commands: [(ActionID, (AgentPaneView) -> Void)] = [
            ("agentPane.toggleDisplaySettings", { $0.toggleDisplaySettings() }),
            ("agentPane.replayConversation", { $0.replayConversation() }),
            ("agentPane.editInstructions", { $0.editProjectInstructions() }),
            ("agentPane.addProjectFiles", { $0.addProjectFiles() }),
            ("agentPane.moveToFloatingChat", { $0.moveToFloatingChat() }),
            ("agentPane.toggleMinimap", { $0.toggleThreadMinimap() }),
        ]
        for (id, command) in commands {
            registry.bind(id, run: { invocation in
                // `focuses` descriptors grant view-change permission through the task-local
                // ActionRunScope for CLI/MCP runs; the raw invocation remains automation-scoped.
                guard ActionRunScope.viewChangeAllowed() else {
                    return context.refuse(MiscHandlerStrings.noAgentChat)
                }
                guard let view = chatView(context, invocation) else { return }
                if (id == "agentPane.editInstructions" || id == "agentPane.addProjectFiles"), view.model.remoteChat {
                    return context.refuse(MiscHandlerStrings.noAgentChat)
                }
                command(view)
            })
        }
    }

    private static func bindMarkUnread(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agentPane.markUnread", run: { invocation in
            guard let (tab, pane) = context.daemonTab(invocation), let session = tab.agentSession?.session,
                  !tab.showsUnread, let view = context.services.agentTabs.existingView(tab.id),
                  view.model.sessionId == session else {
                return context.refuse(MiscHandlerStrings.noAgentChat)
            }
            let daemon = context.services.daemon(for: pane)
            // The action's owner is this one mark request. CLI/MCP callers await the registry's
            // tracked work; a palette or menu invocation receives the same refusal if both paths fail.
            // A session switch before the request makes both paths refuse with noAgentChat.
            registry.trackWork(owner: "AgentChatMenuHandlers.markUnread", on: context.services.mainWork) {
                try await markUnread(view: view, tab: tab, session: session, daemon: daemon)
            } then: { result in
                guard case .failure(let error) = result else { return nil }
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                return ActionWorkFailure(refusal: .unavailable, reason: reason)
            }
        })
    }

    /// Marks `session`'s chat in `view` unread: acpmux's mark, else the tab's daemon mark. Both refuse once the
    /// chat shows another session.
    private static func markUnread(view: AgentPaneView, tab: TabModel, session: String, daemon: DaemonService) async throws {
        try await AgentChatMarkUnread(
            acpmux: {
                guard view.model.sessionId == session, tab.agentSession?.session == session else { return false }
                let marked = await AgentPaneMarkUnread(view.model).run()
                // A session switch while the socket was in flight invalidates the tab fallback.
                guard view.model.sessionId == session, tab.agentSession?.session == session else { return false }
                return marked
            },
            daemon: {
                guard view.model.sessionId == session, tab.agentSession?.session == session else {
                    throw ActionFailure(message: MiscHandlerStrings.noAgentChat)
                }
                try TabUnreadMark.set(true, tab: tab, daemon: daemon)
            }
        ).run()
    }

    private static func bindRevealCwd(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agentPane.revealCwdInFinder", run: { invocation in
            guard let view = chatView(context, invocation), !view.model.remoteChat,
                  let cwd = view.model.terminalFolder else {
                return context.refuse(MiscHandlerStrings.noAgentChat)
            }
            NSWorkspace.shared.revealInBackground([URL(fileURLWithPath: cwd)])
        })
        registry.bind("agentPane.openCwdInTerminal", run: { invocation in
            guard let view = chatView(context, invocation), !view.model.remoteChat,
                  let cwd = view.model.terminalFolder,
                  let pane = context.paneController(invocation) else {
                return context.refuse(MiscHandlerStrings.noAgentChat)
            }
            pane.newTerminalTab(cwd: cwd)
        })
    }

    private static func chatView(_ context: AppActionContext, _ invocation: ActionInvocation) -> AgentPaneView? {
        guard let pane = context.scope(invocation).pane,
              let key = context.scope(invocation).tab?.id.rawValue ?? pane.currentTabKey,
              let view = context.services.agentTabs.existingView(key), view.model.sessionId != nil else {
            context.refuse(MiscHandlerStrings.noAgentChat)
            return nil
        }
        return view
    }
}
