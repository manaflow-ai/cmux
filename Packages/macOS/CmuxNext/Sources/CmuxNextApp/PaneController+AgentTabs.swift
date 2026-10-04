import CmuxNextAgentPane

extension PaneController {
    /// New Agent Chat: a new agent tab in this pane, selected. It inherits
    /// the selected tab's context (`agentSeedFromSelectedTab`, #16620).
    func newAgentTab() {
        openAgentTab(seed: agentSeedFromSelectedTab())
    }

    /// A `cmux://session/<id>` link no tab shows: a new agent tab in this
    /// pane on that session, selected, as Duplicate Tab opens one; its page
    /// refuses a session the daemon does not have. `then` gets its id.
    func openAgentSession(_ session: String, then: (@MainActor (String) -> Void)? = nil) {
        openAgentTab(session: session, linked: true, then: then)
    }

    /// Duplicate Tab on an agent tab: the same session. A chat on another Mac's acpmux is refused.
    func duplicateAgentTab(_ key: String) {
        let tabs = services.agentTabs
        guard tabs.lookup(key)?.record.host == tabs.localHost else { return services.registry.refuse(RefusalStrings.agentTabOtherHost) }
        openAgentTab(session: tabs.session(of: key))
    }

    /// An agent chat tab in this pane on the workspace store, selected once the store reports it
    /// (``AgentTabStore/openTab(in:session:seed:newTab:spare:linked:select:then:)``).
    func openAgentTab(session: String? = nil, seed: AgentPaneSeedSource? = nil,
                      newTab: (page: AgentPaneNewTab, handler: NewTabPageHandler)? = nil, spare: AgentPaneView? = nil,
                      linked: Bool = false, select: Bool = true, then: (@MainActor (String) -> Void)? = nil) {
        services.agentTabs.openTab(in: self, session: session, seed: seed, newTab: newTab, spare: spare, linked: linked,
                                   select: select, then: then)
    }
}
