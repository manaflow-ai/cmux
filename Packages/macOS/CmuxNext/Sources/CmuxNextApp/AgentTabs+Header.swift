import CmuxNextAgentPane

/// The chat header and right-click menu (``AgentChatTabActions``), and the tab state the header
/// menu's labels read.
extension AgentTabStore {
    func wireHeader(_ model: AgentPaneModel, key provisional: String) {
        let actions = AgentChatTabActions(tab: { [weak self] in self?.resolve(provisional) ?? provisional },
                                          registry: { [weak self] in self?.actionRegistry })
        model.header = AgentPaneHeaderHooks(run: actions.run, tabState: { [weak self] in
            guard let self else { return [:] }
            let key = resolve(provisional)
            return ["pinned": lookup(key)?.store.tab(id: key)?.pinned ?? false]
        })
        model.chatMenuItems = actions.menuItems
        model.onSearchWeb = actions.searchWeb
    }
}
