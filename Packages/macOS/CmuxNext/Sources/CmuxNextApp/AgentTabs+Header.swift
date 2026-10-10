import CmuxNextAgentPane

/// The chat header and right-click menu (``AgentChatTabActions``), its toggling quick actions
/// (``AgentChatSplitToggles``), and the tab state the header menu's labels read.
extension AgentTabStore {
    func wireHeader(_ model: AgentPaneModel, key provisional: String) {
        let actions = AgentChatTabActions(tab: { [weak self] in self?.resolve(provisional) ?? provisional },
                                          registry: { [weak self] in self?.actionRegistry })
        let toggles = AgentChatSplitToggles()
        model.header = AgentPaneHeaderHooks(run: actions.run, toggle: { [weak self] id, cwd in
            let chat = self?.resolve(provisional) ?? provisional
            toggles.toggle(id, cwd: cwd, chat: chat, store: self?.lookup(chat)?.store, actions: actions)
        }, tabState: { [weak self] in
            guard let self else { return [:] }
            let key = resolve(provisional)
            return ["pinned": lookup(key)?.store.tab(id: key)?.pinned ?? false]
        })
        model.chatMenuItems = actions.menuItems
        model.onSearchWeb = actions.searchWeb
    }
}
