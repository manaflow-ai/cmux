import CmuxNextActions

extension AgentChatTabActions {
    /// Registers the chat's observed header, thread actions, menu and web search together.
    package func registerHeader(on model: AgentPaneModel,
                                cwd: @escaping @MainActor (String) -> String?,
                                local: @escaping @MainActor (String) -> Bool,
                                state: @escaping @MainActor () -> AgentPaneHeaderState,
                                push: @escaping @MainActor (AgentPaneHeaderState) -> Void,
                                hooks: (AgentChatHeaderWatch) -> AgentPaneHeaderHooks) {
        let watch = AgentChatHeaderWatch(state: state, push: push)
        // Watching from the wiring on: a tab rekeyed after the page's first read is wired again,
        // and its new watch must push without waiting for another read.
        watch.read()
        model.header = hooks(watch)
        AgentChatThreadActions().wire(&model.header, tab: tab, registry: registry, cwd: cwd,
                                      local: local, files: { openFiles($0, on: $1) },
                                      changes: { runBeside("openDiffViewer", arguments: ["path": .string($0)], on: $1) })
        model.chatMenuItems = menuItems
        model.onSearchWeb = searchWeb
    }
}
