import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// The chat header and right-click menu (``AgentChatTabActions``), its toggling quick actions
/// (``AgentChatSplitToggles``), the header's state, pushed when it changes (``AgentChatHeaderWatch``),
/// and New side chat's split.
extension AgentTabStore {
    func wireHeader(_ model: AgentPaneModel, key provisional: String) {
        let actions = AgentChatTabActions(tab: { [weak self] in self?.resolve(provisional) ?? provisional },
                                          registry: { [weak self] in self?.actionRegistry }, files: { [weak self] in self?.openFiles?(self?.resolve(provisional) ?? provisional, $0, $1) }, hidden: { [weak self] in CloudMove.hiddenMenuItems(self?.lookup(self?.resolve(provisional) ?? provisional)?.record) }, local: { [weak self] in self.flatMap { $0.gitLink?($0.resolve(provisional)) }?.isLocal == true })
        let toggles = AgentChatSplitToggles(), pullRequest = AgentChatPullRequest()
        let watch = AgentChatHeaderWatch(state: { [weak self] in
            guard let self else { return AgentPaneHeaderState() }
            let chat = resolve(provisional)
            return toggles.headerState(chat: chat, store: lookup(chat)?.store, pullRequest: gitLink?(chat)?.isLocal == true ? pullRequest : nil)
        }, push: { [weak self] state in
            guard let view = self?.existingView(provisional) else { return }
            AgentPaneHeaderState.push(state, to: view)
        })
        // Watching from the wiring on: a tab rekeyed after the page's first read is wired again,
        // and its new watch must push without waiting for another read.
        watch.read()
        model.header = AgentPaneHeaderHooks(run: { [weak self] id, cwd in
            let chat = self?.resolve(provisional) ?? provisional
            toggles.open(id, cwd: cwd, chat: chat, store: self?.lookup(chat)?.store, actions: actions)
        }, toggle: { [weak self] id, cwd in
            let chat = self?.resolve(provisional) ?? provisional
            toggles.toggle(id, cwd: cwd, chat: chat, store: self?.lookup(chat)?.store, actions: actions)
        }, tabState: {
            // The page reads the state when a chat opens; its changes are pushed.
            watch.read()
        }, openSide: { [weak self] in _ = self?.openSide($0, beside: provisional) }, openTab: { [weak self] in self?.openSide($0, beside: provisional, split: false) ?? false }, newChat: { [weak self] in self?.openNewTabColumn(beside: provisional, cwd: $0, split: false) ?? false }, openSubagent: { [weak self] session, agent, focus in
            self?.openSubagent(agent, of: session, focus: focus, beside: provisional) ?? false
        }, sideTabs: { [weak self] in
            guard let self else { return nil }
            let chat = resolve(provisional)
            return toggles.sideTabs(chat: chat, store: lookup(chat)?.store, actions: actions) { [weak self] in
                self?.openNewTabColumn(beside: provisional) ?? false
            }
        }, preview: { [weak self] url, toggle in
            let chat = self?.resolve(provisional) ?? provisional
            let store = self?.lookup(chat)?.store, id = AgentPaneModel.previewAction
            if toggle { toggles.toggle(id, cwd: nil, url: url, chat: chat, store: store, actions: actions) }
            else { toggles.open(id, cwd: nil, url: url, chat: chat, store: store, actions: actions) }
        }, saveQuickActions: { [weak self] list in
            await self?.customization.saveQuickActions(list) ?? false
        }, moveToFloatingChat: { [weak self] session in actions.moveToFloatingChat(session, via: self?.moveToFloatingChat) }, refreshPullRequest: pullRequest.askAgain)
        model.chatMenuItems = actions.menuItems
        model.onSearchWeb = actions.searchWeb
    }

    /// A tab on `session` in the chat's pane, then (`split`, New side chat) moved to a new split on its
    /// right (`tab.moveToNewSplit`), so the chat stays where it is; a fork or Continue in… stays a tab.
    private func openSide(_ session: String, beside provisional: String, split: Bool = true) -> Bool {
        openBeside(provisional, split: split) { pane, daemon in try self.open(in: pane, of: daemon, session: session) }
    }

    /// [+] New tab's column: a New Tab page in the chat's folder (or `cwd`, New Chat Here), moved to
    /// a new split on its right as New side chat's tab is unless not `split`. The page's choices
    /// replace it in whichever pane it is in then. Returns whether the page was started.
    private func openNewTabColumn(beside provisional: String, cwd: String? = nil, split: Bool = true) -> Bool {
        let chat = resolve(provisional)
        // The page opens on the chat's machine: that machine's folders, never this Mac's (cx-k21v).
        guard let newTab = firstPageNewTab?(cwd ?? lookup(chat)?.store.tab(id: chat)?.cwd, chat) else { return false }
        return openBeside(provisional, split: split) { pane, daemon in try self.open(in: pane, of: daemon, newTab: newTab) }
    }

    /// A subagent's pane (``AgentSubagentPanes``): the open one, focused with `focus`; else a tab on
    /// the chat's session that shows the subagent, in a new split right of the chat, or below the
    /// newest subagent pane. Without `focus` the move is not a view change: focus stays in the chat.
    private func openSubagent(_ agent: String, of session: String, focus: Bool, beside provisional: String) -> Bool {
        let panes = subagentPanes[session] ?? AgentSubagentPanes()
        subagentPanes[session] = panes
        let isOpen = { [weak self] (key: String) in self?.locate(key) != nil }
        if let open = panes.tab(for: agent, isOpen: isOpen) {
            if focus { _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: open))) }
            return true
        }
        guard panes.begin(agent, focus: focus, chat: provisional) else { return true }
        let next: @MainActor (Bool) -> Void = { [weak self] moved in
            // The daemon's move-tab-to-split focuses the new pane; an unfocused open gives focus back
            // to the chat (cx-3hw0i: a move that keeps focus, in the daemon).
            if moved, !focus, let self { _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .tab, id: resolve(provisional)), arguments: ["focus": .bool(true)], origin: .script)) }
            if let request = panes.finish() { _ = self?.openSubagent(request.agent, of: session, focus: request.focus, beside: request.chat) }
        }
        let stack = panes.stackAnchor(isOpen: isOpen)
        let opened = openBeside(stack ?? provisional, direction: stack == nil ? "right" : "down", origin: focus ? .user : .script,
                                open: { pane, daemon in try self.open(in: pane, of: daemon, session: session) },
                                created: { [weak self] key in
            panes.record(agent, tab: key)
            self?.revealTurn(AgentSubagentPanes.reveal(agent), in: key)
        }, finished: next)
        if !opened { next(false) }
        return opened
    }

    @discardableResult
    private func openBeside(_ provisional: String, split: Bool = true, direction: String = "right", origin: ActionOrigin = .user,
                            open: (PaneID, DaemonService) throws -> AgentTabPending, created: (@MainActor (String) -> Void)? = nil,
                            finished: (@MainActor (_ moved: Bool) -> Void)? = nil) -> Bool {
        guard let (pane, daemon) = locate(resolve(provisional)), let pending = try? open(pane, daemon) else { return false }
        guard split else { return true }
        // task-owner: one tab creation, then one move of that tab
        Task { [weak self] in
            var moved = false
            defer { finished?(moved) }
            guard let tab = try? await pending.value(), let self, await TabMirror.reaches(tab.key, in: locate) else { return }
            created?(tab.key)
            _ = actionRegistry?.perform("tab.moveToNewSplit", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .tab, id: tab.key), arguments: ["direction": .string(direction)], origin: origin))
            // A later subagent pane stacks under this one: wait (bounded) until it left the anchor's pane.
            if finished != nil { moved = await TabMirror.reaches(tab.key, in: locate) { $0 != pane } }
        }
        return true
    }
}
