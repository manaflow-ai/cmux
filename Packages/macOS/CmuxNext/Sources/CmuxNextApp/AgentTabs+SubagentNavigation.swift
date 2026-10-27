import CmuxNextLayout
import CmuxNextActions
import CmuxNextAgentPane

extension AgentTabStore {
    /// Reuse only a tab in this chat's right pane, on its acpmux host. A tab in another
    /// workspace must never pull the person away from the chat they clicked in.
    @MainActor func showSessionBeside(_ session: String, chat: String, host: String? = nil) -> Bool {
        let source = resolve(chat), host = host ?? lookup(resolve(chat))?.record.host ?? localHost
        guard let tab = subagentTabsBeside(source).first(where: {
            $0.record.host == host && self.session(of: $0.key) == session && isBeside(source, resolve($0.key))
        }) else { return false }
        return actionRegistry?.perform("tab.focus", invocation: .init(target: .init(kind: .tab, id: resolve(tab.key)), origin: .user)) == true
    }

    /// The side-session queue serializes placement; queued re-clicks recheck reuse after the
    /// first tab lands. Keyed by source tab so the same chat in another workspace stays there.
    @discardableResult
    @MainActor func openChildBeside(_ session: String, beside chat: String, host: String? = nil) -> Bool {
        let source = resolve(chat), host = host ?? lookup(resolve(chat))?.record.host
        return AgentSidePanes.chat(source).open(session, chat: source, pane: { [weak self] key in
            guard let self, isBeside(resolve(source), resolve(key)) else { return nil }
            return locate(resolve(key))?.pane.rawValue
        }) { [weak self] anchor, created, finished in
            guard let self else { return false }
            if showSessionBeside(session, chat: source, host: host) { finished(); return true }
            return openBeside(anchor ?? source, split: anchor == nil, main: source, open: { [weak self] pane, daemon in
                guard let self else { throw CancellationError() }
                return try open(in: pane, of: daemon, session: session, host: daemon.isLocal || host != lookup(source)?.record.host ? host : nil)
            }, created: created, finished: { _ in finished() })
        }
    }
}

extension AppServices {
    /// Same column order and right-neighbor fallback used by links, including split layouts.
    @MainActor func subagentSidePane(of chat: String) -> PaneController? {
        guard let (_, pane) = locateTab(chat), let source = paneController(for: pane), let content = source.workspace else { return nil }
        if case .tab(let id) = MainPaneLayout.side(from: source, services: self) { return content.panes[id] }
        let takes: (LayoutPaneID) -> Bool = { content.panes[$0]?.stripModel.showsNewTabButton == true }
        if !source.stripModel.showsNewTabButton, let screen = content.layoutModel.screen(containing: source.layoutPaneID),
           let id = LinkOpenPlacement<LayoutPaneID>.paneRight(of: source.layoutPaneID,
               columns: screen.layout.visualColumns.map(\.root.panes), takesTabs: takes, recency: content.recentPanes) {
            return content.panes[id]
        }
        return PaneHandlers.neighbor(of: source.layoutPaneID, direction: .right, in: content).flatMap { takes($0) ? content.panes[$0] : nil }
    }
}
