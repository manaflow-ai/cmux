import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextWindowRules

/// Native bindings for rows in an agent chat's header and "..." menu.
/// Every binding resolves the focused pane at run time, then calls the page or
/// host path used by the existing menu. This keeps a stale palette invocation
/// from acting on another chat after a session switch. A row that cannot run on its chat is disabled
/// (`ActionRegistry.gate(_:onRefusalOf:)` on the same lookup); its shortcut does nothing (Leo 2026-11-17).
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
            // The started chat the row acts on, else nil after refusing with why; also gates the row.
            let target: @MainActor (ActionInvocation) -> AgentPaneView? = { invocation in
                chatView(id, context, invocation).flatMap { row.refusesRemote && $0.model.remoteChat ? context.registry.refuse(.remote, id) : $0 }
            }
            registry.bind(id, run: { invocation in
                // `focuses` descriptors grant view-change permission through the task-local
                // ActionRunScope for CLI/MCP runs; the raw invocation remains automation-scoped.
                guard ActionRunScope.viewChangeAllowed() else {
                    return context.registry.refuse(.needsFocus, id)
                }
                if let view = target(invocation) { command(view) }
            })
            registry.gate(id) { _ = target($0) }
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
                  let view = context.services.agentTabs.existingView(tab.id), view.model.sessionId == session else {
                return context.registry.refuse(.noChat, "agentPane.markUnread")
            }
            if tab.showsUnread { return } // already unread: nothing to do, nothing to say
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
            // Owner: this one mark request; CLI/MCP callers await the tracked work, a palette or menu run gets the same refusal.
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
        registry.gate("agentPane.markUnread") { run in if let tab = context.daemonTab(run)?.tab, tab.agentSession?.session == nil { context.registry.refuse(.noChat, "agentPane.markUnread") } }
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
        registry.gate("agentPane.revealCwdInFinder") { _ = localFolder("agentPane.revealCwdInFinder", context, $0) }
        registry.gate("agentPane.openCwdInTerminal") { run in _ = context.paneController(run).flatMap { localFolder("agentPane.openCwdInTerminal", context, run, shellOn: $0) } }
    }

    private static func chatView(_ id: ActionID, _ context: AppActionContext, _ invocation: ActionInvocation) -> AgentPaneView? {
        if let chat = rowChat(invocation) { return openView(chat, context) ?? context.registry.refuse(.noChat, id) }
        guard let pane = context.scope(invocation).pane,
              let key = context.scope(invocation).tab?.id.rawValue ?? pane.currentTabKey,
              let view = context.services.agentTabs.existingView(key) else {
            return context.registry.refuse(.noChat, id)
        }
        return view.model.sessionId == nil ? context.registry.refuse(.notStarted, id) : view
    }

    /// A Priority row's chat (its `agent-chat:` target, as Archive Chat reads it): a tab here shows it, else its lane's folder.
    private static func rowChat(_ invocation: ActionInvocation) -> String? { invocation.target?.kind == .agentChat ? invocation.target?.id : nil }
    private static func openView(_ chat: String, _ context: AppActionContext) -> AgentPaneView? { context.services.agentTabs.tab(showing: chat).flatMap { context.services.agentTabs.existingView($0) } }

    /// The project folder of the chat `id` runs on, on this Mac or, for a shell in `pane` on the chat's own machine, there; else nil after refusing with why.
    static func localFolder(_ id: ActionID, _ context: AppActionContext, _ invocation: ActionInvocation, shellOn pane: PaneController? = nil) -> String? {
        if let chat = rowChat(invocation), openView(chat, context) == nil { return laneFolder(id, chat, local: true, context) }
        guard let view = chatView(id, context, invocation) else { return nil }
        return !view.model.remoteChat ? view.model.terminalFolder ?? context.registry.refuse(.noFolder, id) : (rowChat(invocation) == nil ? pane : nil).flatMap { pane in (context.scope(invocation).tab?.id.rawValue ?? pane.currentTabKey).flatMap { context.services.agentTabs.terminalFolder(of: $0, on: pane.daemon) } } ?? context.registry.refuse(.remote, id)
    }

    /// The chat's folder on its own machine (Copy Path: a remote chat's remote path); nil after refusing with why.
    static func anyFolder(_ id: ActionID, _ context: AppActionContext, _ invocation: ActionInvocation) -> String? {
        if let chat = rowChat(invocation), openView(chat, context) == nil { return laneFolder(id, chat, local: false, context) }
        return chatView(id, context, invocation).map { $0.model.terminalFolder ?? context.registry.refuse(.noFolder, id) } ?? nil
    }

    private static func laneFolder(_ id: ActionID, _ chat: String, local: Bool, _ context: AppActionContext) -> String? {
        do { return try AgentPriorityChats.app.folder(of: chat, local: local).get() } catch { return context.registry.refuse(error.cause, id) }
    }

    /// Open in Editor, Open In ▸, Copy Path, Reveal Workspace in Finder, Open Terminal Here (``EditorActions``).
    static func bindEditors(into registry: ActionRegistry, context: AppActionContext) {
        let machines = context.services.machines, windows = context.services.windows
        EditorActions.bind(into: registry, catalog: context.services.editorCatalog, host: EditorActions.Host(
            chatFolder: { $2 ? localFolder($0, context, $1) : anyFolder($0, context, $1) },
            workspaceFolder: { id, invocation in
                guard let workspace = try? context.workspace(invocation).model else { return context.refuseQuietly(RefusalStrings.noWorkspaceToActOn) }
                guard (machines.daemon(forWorkspace: workspace.id) ?? machines.local).isLocal else { return context.registry.refuse(.remote, id) }
                return WorkspaceVerbHandlers.directory(of: workspace, context, terminalsOnly: false) ?? context.refuseQuietly(RefusalStrings.workspaceHasNoDirectory)
            }, copy: context.copy,
            openTerminal: { folder, invocation in
                guard let workspace = try? context.workspace(invocation).model, let owner = windows.actingWindow(for: workspace.id), let controller = windows.controller(for: owner), controller.state.workspaceID == workspace.id, let pane = controller.focusedPane else { return .refused(MiscHandlerStrings.noPane) }
                pane.newTerminalTab(cwd: folder)
                return .done
            }))
    }
}
