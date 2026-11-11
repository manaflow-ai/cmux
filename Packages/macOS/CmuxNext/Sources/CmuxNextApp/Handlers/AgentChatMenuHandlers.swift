import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextWindowRules

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

    /// The page commands the rows run (cmux-window-rules `chat::agent::tables`), and which a remote chat refuses.
    private static func bindPageCommands(into registry: ActionRegistry, context: AppActionContext) {
        for row in WindowRules.chatAgentTables?.pageCommands ?? [] {
            guard let command = pageCommand(row.command) else { continue }
            let id = ActionID(rawValue: row.action)
            registry.bind(id, run: { invocation in
                // `focuses` descriptors grant view-change permission through the task-local
                // ActionRunScope for CLI/MCP runs; the raw invocation remains automation-scoped.
                guard ActionRunScope.viewChangeAllowed() else {
                    return context.registry.refuse(.needsFocus, id)
                }
                guard let view = chatView(id, context, invocation) else { return }
                if row.refusesRemote, view.model.remoteChat {
                    return context.registry.refuse(.remote, id)
                }
                command(view)
            })
        }
    }

    /// The page's method for a table command.
    private static func pageCommand(_ command: String) -> ((AgentPaneView) -> Void)? {
        switch command {
        case "toggleDisplaySettings": return { $0.toggleDisplaySettings() }
        case "replayConversation": return { $0.replayConversation() }
        case "editProjectInstructions": return { $0.editProjectInstructions() }
        case "addProjectFiles": return { $0.addProjectFiles() }
        case "moveToFloatingChat": return { $0.moveToFloatingChat() }
        case "toggleThreadMinimap": return { $0.toggleThreadMinimap() }
        case "continueAfterError": return { $0.continueAfterError() }
        default: return nil
        }
    }

    private static func bindMarkUnread(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agentPane.markUnread", run: { invocation in
            guard let (tab, pane) = context.daemonTab(invocation), let session = tab.agentSession?.session,
                  !tab.showsUnread, let view = context.services.agentTabs.existingView(tab.id),
                  view.model.sessionId == session else {
                return context.registry.refuse(.noChat, "agentPane.markUnread")
            }
            let daemon = context.services.daemon(for: pane)
            let mark = AgentChatMarkUnread(
                acpmux: {
                    guard view.model.sessionId == session, tab.agentSession?.session == session else { return false }
                    let marked = await AgentPaneMarkUnread(view.model).run()
                    // A session switch while the socket was in flight invalidates the tab fallback.
                    guard view.model.sessionId == session, tab.agentSession?.session == session else { return false }
                    return marked
                },
                daemon: {
                    guard view.model.sessionId == session, tab.agentSession?.session == session else {
                        throw ActionFailure(message: context.registry.reason(.noChat, for: "agentPane.markUnread"))
                    }
                    try TabUnreadMark.set(true, tab: tab, daemon: daemon)
                }
            )
            // The action's owner is this one mark request. CLI/MCP callers await the registry's
            // tracked work; a palette or menu invocation receives the same refusal if both paths fail.
            registry.track(Task { @MainActor in
                guard view.model.sessionId == session, tab.agentSession?.session == session else {
                    return ActionWorkFailure(refusal: .unavailable, reason: context.registry.reason(.noChat, for: "agentPane.markUnread"))
                }
                do {
                    try await mark.run()
                    return nil
                } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    return ActionWorkFailure(refusal: .unavailable, reason: reason)
                }
            })
        })
    }

    private static func bindRevealCwd(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agentPane.revealCwdInFinder", run: { invocation in
            guard let cwd = localFolder("agentPane.revealCwdInFinder", context, invocation) else { return }
            NSWorkspace.shared.revealInBackground([URL(fileURLWithPath: cwd)])
        })
        registry.bind("agentPane.openCwdInTerminal", run: { invocation in
            guard let pane = context.paneController(invocation) ?? context.registry.refuse(.noChat, "agentPane.openCwdInTerminal"),
                  let cwd = localFolder("agentPane.openCwdInTerminal", context, invocation, shellOn: pane) else { return }
            pane.newTerminalTab(cwd: cwd)
        })
    }

    private static func chatView(_ id: ActionID, _ context: AppActionContext, _ invocation: ActionInvocation) -> AgentPaneView? {
        guard let pane = context.scope(invocation).pane,
              let key = context.scope(invocation).tab?.id.rawValue ?? pane.currentTabKey,
              let view = context.services.agentTabs.existingView(key) else {
            return context.registry.refuse(.noChat, id)
        }
        return view.model.sessionId == nil ? context.registry.refuse(.notStarted, id) : view
    }

    /// The project folder of the chat `id` runs on, on this Mac or, for a shell in `pane` on the chat's own machine, there; else nil after refusing with why.
    private static func localFolder(_ id: ActionID, _ context: AppActionContext, _ invocation: ActionInvocation, shellOn pane: PaneController? = nil) -> String? {
        guard let view = chatView(id, context, invocation) else { return nil }
        return !view.model.remoteChat ? view.model.terminalFolder ?? context.registry.refuse(.noFolder, id) : pane.flatMap { pane in (context.scope(invocation).tab?.id.rawValue ?? pane.currentTabKey).flatMap { context.services.agentTabs.terminalFolder(of: $0, on: pane.daemon) } } ?? context.registry.refuse(.remote, id)
    }
}
