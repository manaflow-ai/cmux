import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// The chat header and right-click menu (``AgentChatTabActions``), its toggling quick actions
/// (``AgentChatSplitToggles``), the tab state the header menu's labels read, and New side chat's
/// split.
extension AgentTabStore {
    func wireHeader(_ model: AgentPaneModel, key provisional: String) {
        let actions = AgentChatTabActions(tab: { [weak self] in self?.resolve(provisional) ?? provisional },
                                          registry: { [weak self] in self?.actionRegistry })
        let toggles = AgentChatSplitToggles()
        model.header = AgentPaneHeaderHooks(run: { [weak self] id, cwd in
            let chat = self?.resolve(provisional) ?? provisional
            toggles.open(id, cwd: cwd, chat: chat, store: self?.lookup(chat)?.store, actions: actions)
        }, toggle: { [weak self] id, cwd in
            let chat = self?.resolve(provisional) ?? provisional
            toggles.toggle(id, cwd: cwd, chat: chat, store: self?.lookup(chat)?.store, actions: actions)
        }, tabState: { [weak self] in
            guard let self else { return [:] }
            let key = resolve(provisional)
            return ["pinned": lookup(key)?.store.tab(id: key)?.pinned ?? false]
        }, openSide: { [weak self] session in self?.openSide(session, beside: provisional) })
        model.chatMenuItems = actions.menuItems
        model.onSearchWeb = actions.searchWeb
    }

    /// A tab on `session` in the chat's pane, then moved to a new split on its right
    /// (`tab.moveToNewSplit`), so the chat stays where it is.
    private func openSide(_ session: String, beside provisional: String) {
        guard let (pane, daemon) = locate(resolve(provisional)),
              let pending = try? open(in: pane, of: daemon, session: session) else { return }
        // task-owner: one tab creation, then one move of that tab
        Task { [weak self] in
            guard let created = try? await pending.value() else { return }
            let target = ActionTargetRef(kind: .tab, id: created.key)
            _ = self?.actionRegistry?.perform("tab.moveToNewSplit", invocation: ActionInvocation(
                target: target, arguments: ["direction": .string("right")], origin: .user))
        }
    }
}
