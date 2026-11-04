public import CmuxNextDaemon

extension HomeDock {
    /// The browser tab a Chief card's Open browser selects (cmux issue 25830, `browser:right`): in the
    /// first pane of the scrolling column right of the Home chat on `home` (the column every Chief
    /// drives with `cmux browser right`), the agent's own tab (`agentProfile`) first, else the tab
    /// that pane shows, else its last browser tab. Nil with no such column or browser tab.
    public static func chiefBrowserTab(home: WorkspaceModel?, agentProfile: String) -> String? {
        guard let home, let placed = pageTab(in: home), let beside = besidePane(of: placed.pane, on: placed.screen) else { return nil }
        let browsers = beside.tabs.filter { $0.kind == .browser && $0.page == nil }
        let agent = browsers.last { $0.browserProfileID?.lowercased() == agentProfile.lowercased() }
        let shown = beside.tabs.enumerated().first { $0.offset == beside.defaultTabIndex }?.element
        let selected = shown.flatMap { tab in browsers.first { $0.id == tab.id } }
        return (agent ?? selected ?? browsers.last)?.id
    }

    /// The first pane of the scrolling column right of `chat` on `screen` (for a chat in a dock, the
    /// strip's first column), as `cmux identify`'s `beside` names it.
    static func besidePane(of chat: PaneModel, on screen: ScreenModel) -> PaneModel? {
        guard let index = screen.columns.firstIndex(where: { $0.layout.paneIDs.contains(chat.handle) }),
              let own = screen.columns.dropFirst(index).first else { return nil }
        let candidates = own.dock == nil ? Array(screen.columns.dropFirst(index + 1)) : screen.columns
        guard let column = candidates.first(where: { $0.dock == nil && !$0.layout.paneIDs.contains(chat.handle) }),
              let first = column.layout.paneIDs.first else { return nil }
        return screen.panes.first { $0.handle == first }
    }
}
