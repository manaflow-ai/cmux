import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// The chat header and right-click menu (``AgentChatTabActions``), its toggling quick actions
/// (``AgentChatSplitToggles``), the header's state, pushed when it changes (``AgentChatHeaderWatch``),
/// and the side pane New side chat and `/btw` open in (``AgentSidePanes``).
extension AgentTabStore {
    func wireHeader(_ model: AgentPaneModel, key provisional: String) {
        let actions = AgentChatTabActions(tab: { [weak self] in self?.resolve(provisional) ?? provisional },
                                          registry: { [weak self] in self?.actionRegistry }, files: { [weak self] in self?.openFiles?(self?.resolve(provisional) ?? provisional, $0, $1) }, hidden: { [weak self] in CloudMove.hiddenMenuItems(self?.lookup(self?.resolve(provisional) ?? provisional)?.record) }, splitInherits: { NewTerminalStart.inherits(.split) }, local: { [weak self] in self.flatMap { $0.gitLink?($0.resolve(provisional)) }?.isLocal == true })
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
        }, openSide: { [weak self] chat, fork in // the tracker (AgentSidePanes) picks the side pane's tab or a new split; the app opens there
            guard let self else { return }; AgentSidePanes.chat(chat).open(fork, chat: resolve(provisional), pane: { [weak self] in self?.locate(self?.resolve($0) ?? $0).map { "\(ObjectIdentifier($0.daemon).hashValue):\($0.pane.rawValue)" } }) { [weak self] anchor, created, finished in
                self?.openBeside(anchor ?? provisional, split: anchor == nil, open: { [weak self] pane, daemon in guard let self else { throw CancellationError() }; return try open(in: pane, of: daemon, session: fork) }, created: created, finished: { _ in finished() }) ?? false }
        }, openTab: { [weak self] session in guard let self else { return false }; return openBeside(provisional, split: false) { pane, daemon in try self.open(in: pane, of: daemon, session: session) } }, openSubagent: { [weak self] in self?.openSubagent($1, of: $0, focus: $2, beside: provisional) ?? false }, openProcess: { [weak self] viewer in guard let self else { return false }; return openProcess?(resolve(provisional), viewer) ?? false }, newChat: { [weak self] in self?.openNewTabColumn(beside: provisional, cwd: $0, split: false) ?? false }, sideTabs: { [weak self] in
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
        AgentChatThreadActions().wire(&model.header, tab: { [weak self] in self?.resolve(provisional) ?? provisional },
                                      registry: { [weak self] in self?.actionRegistry }, cwd: { [weak self] in self?.lookup($0)?.store.tab(id: $0)?.cwd })
        model.chatMenuItems = actions.menuItems
        model.onSearchWeb = actions.searchWeb
    }

    /// [+] New tab's column: a New Tab page in the chat's folder (or `cwd`, New Chat Here), moved to
    /// a new split on its right unless not `split`. The page's choices
    /// replace it in whichever pane it is in then. Returns whether the page was started.
    private func openNewTabColumn(beside provisional: String, cwd: String? = nil, split: Bool = true) -> Bool {
        let chat = resolve(provisional)
        // The page opens on the chat's machine: that machine's folders, never this Mac's (cx-k21v).
        guard let newTab = firstPageNewTab?(cwd ?? lookup(chat)?.store.tab(id: chat)?.cwd, chat) else { return false }
        return openBeside(provisional, split: split) { pane, daemon in try self.open(in: pane, of: daemon, newTab: newTab) }
    }

    private func openSubagent(_ agent: String, of session: String, focus: Bool, beside provisional: String) -> Bool { // the tracker (AgentSubagentPanes) decides; the app opens and moves the tab
        AgentSubagentPanes.session(session).open(agent, focus: focus, chat: provisional, hooks: .init(isOpen: { [weak self] in self?.locate($0) != nil }, focus: { [weak self] key, script in _ = self?.actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: self?.resolve(key) ?? key), arguments: script ? ["focus": .bool(true)] : [:], origin: script ? .script : .user)) },
            place: { [weak self] anchor, down, created, finished in self?.openBeside(anchor, direction: down ? "down" : "right", origin: focus ? .user : .script, open: { [weak self] pane, daemon in guard let self else { throw CancellationError() }; return try open(in: pane, of: daemon, session: session) },
                created: { [weak self] in created($0); self?.revealTurn(AgentSubagentPanes.reveal(agent), in: $0) }, finished: finished) ?? false }, again: { [weak self] request in _ = self?.openSubagent(request.agent, of: session, focus: request.focus, beside: request.chat) })) }
    /// A tab in chat tab `provisional`'s pane, then moved to a new split on its right when `split`; else a tab there, focused when `created` is set.
    @discardableResult
    private func openBeside(_ provisional: String, split: Bool = true, direction: String = "right", origin: ActionOrigin = .user, open: (PaneID, DaemonService) throws -> AgentTabPending, created: (@MainActor (String) -> Void)? = nil, finished: (@MainActor (_ moved: Bool) -> Void)? = nil) -> Bool {
        guard let (pane, daemon) = locate(resolve(provisional)), let pending = try? open(pane, daemon) else { return false }
        guard split || created != nil else { return true }
        // task-owner: one tab creation, then one move (or, not `split`, one focus) of that tab
        Task { [weak self] in
            guard let tab = try? await pending.value(), let self, await TabMirror.reaches(tab.key, in: locate) else { finished?(false); return }; created?(tab.key)
            guard split else { _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), origin: origin)); finished?(false); return }
            _ = actionRegistry?.perform("tab.moveToNewSplit", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), arguments: ["direction": .string(direction), "keep_focus": .bool(origin == .script)], origin: origin)) // script: an unfocused subagent open
            if let finished { finished(await TabMirror.reaches(tab.key, in: { [weak self] in self?.locate($0).flatMap { $0.pane != pane ? $0 : nil } })) } // stacking waits for the move
        }
        return true
    }
}
