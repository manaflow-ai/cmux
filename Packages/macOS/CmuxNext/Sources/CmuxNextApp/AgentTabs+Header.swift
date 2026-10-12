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
        }, openSide: { [weak self] session in self?.openSide(session, beside: provisional) }, sideTabs: { [weak self] in
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

    /// A tab on `session` in the chat's pane, then moved to a new split on its right
    /// (`tab.moveToNewSplit`), so the chat stays where it is.
    private func openSide(_ session: String, beside provisional: String) {
        openBeside(provisional) { pane, daemon in try self.open(in: pane, of: daemon, session: session) }
    }

    /// [+] New tab's column: a New Tab page in the chat's folder, moved to a new split on its right
    /// as New side chat's tab is. The page's choices replace it in whichever pane it is in then.
    /// Returns whether the page was started.
    private func openNewTabColumn(beside provisional: String) -> Bool {
        let chat = resolve(provisional)
        // The page opens on the chat's machine: that machine's folders, never this Mac's (cx-k21v).
        guard let newTab = firstPageNewTab?(lookup(chat)?.store.tab(id: chat)?.cwd, chat) else { return false }
        return openBeside(provisional) { pane, daemon in try self.open(in: pane, of: daemon, newTab: newTab) }
    }

    @discardableResult
    private func openBeside(_ provisional: String, open: (PaneID, DaemonService) throws -> AgentTabPending) -> Bool {
        guard let (pane, daemon) = locate(resolve(provisional)),
              let pending = try? open(pane, daemon) else { return false }
        // task-owner: one tab creation, then one move of that tab
        Task { [weak self] in
            guard let created = try? await pending.value(), let self, await TabMirror.reaches(created.key, in: locate) else { return }
            let target = ActionTargetRef(kind: .tab, id: created.key)
            _ = actionRegistry?.perform("tab.moveToNewSplit", invocation: ActionInvocation(
                target: target, arguments: ["direction": .string("right")], origin: .user))
        }
        return true
    }
}
