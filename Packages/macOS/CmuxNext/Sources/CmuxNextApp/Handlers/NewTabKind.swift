import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings

/// What Cmd-T opens in a pane.
nonisolated enum NewTabKind: Equatable, Sendable {
    case terminal
    /// A browser tab on `engine` (nil: `browser.defaultEngine`).
    case browser(engine: String?)
    case agent
    /// The new tab page, to pick the kind.
    case page

    /// The pane's selected tab decides: a browser tab (daemon or
    /// session-local) gets a browser tab on its engine, so cookies and
    /// extensions stay in that engine; an agent tab gets an agent tab; a
    /// terminal, a remote terminal or an empty pane gets a terminal tab.
    static func resolve(selectedKind: TabKind?, engine: String?, isLocalBrowser: Bool, isAgent: Bool = false) -> NewTabKind {
        if isAgent { return .agent }
        if selectedKind == .browser { return .browser(engine: engine) }
        if isLocalBrowser { return .browser(engine: nil) }
        return .terminal
    }

    /// The action that opens this kind on its own, whose title New <Kind> Tab takes in a tab's menu.
    var newActionID: ActionID {
        switch self {
        case .terminal: "newSurface"
        case .browser: "openBrowser"
        case .agent: "palette.newAgentChat"
        case .page: "newTab.page"
        }
    }

    /// The kind New <Kind> Tab opens next to tab `id`, as the user sees it:
    /// agent tabs and New Tab pages count (`newTabOfPaneKind`).
    @MainActor static func of(_ id: String, tab: TabModel?, services: AppServices) -> NewTabKind {
        let agent = services.agentTabs.isAgentTab(id)
        if agent, services.agentTabs.isNewTabPage(id) { return .page }
        return resolve(selectedKind: tab?.kind, engine: tab?.browserEngine, isLocalBrowser: id.hasPrefix(LocalBrowserTab.prefix), isAgent: agent)
    }
}
