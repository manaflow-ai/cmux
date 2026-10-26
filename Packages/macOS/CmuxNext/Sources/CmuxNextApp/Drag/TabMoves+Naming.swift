import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextWorkspaceNaming

// MARK: The name of a workspace a move makes

extension TabMoves {
    /// The name a workspace made from `tab` takes: the tab's, or, when
    /// `tab` is its workspace's last daemon tab, the workspace's own name
    /// when the user named it (the workspace closes behind the move).
    static func newWorkspaceName(for tab: TabModel, services: AppServices) -> String? {
        // An agent chat's name is its chat's title, which only the turn store knows.
        let tabName = WorkspaceAutoNameWiring(services: services).reader.newWorkspaceName(tab)
        guard let sourceID = services.workspaceID(ofTab: tab.id), let source = services.workspace(id: sourceID),
              source.screens.flatMap(\.panes).flatMap(\.tabs).count == 1 else { return tabName }
        // The source workspace's own daemon, as WorkspaceAutoNameWiring reads it (none: legacy defaults apply).
        let daemon = services.machines.daemon(forWorkspace: sourceID)
        return NewWorkspaceName.forLastTab(workspaceName: source.name, workspaceTitle: source.title, tabName: tabName,
                                           workspaceNameSource: source.nameSource, workspaceNameRevision: source.nameRevision,
                                           allowsLegacyDefaults: !(daemon?.supports(DaemonCapability.workspaceNameSource.rawValue) ?? false))
    }

    /// What `NewWorkspaceName` reads from `tab`: the browser's live page
    /// title comes from the app's renderer, the rest from the store. An
    /// incognito page's title stays in memory (R102): the daemon stores the
    /// workspace name and keeps it in closed history.
    static func nameInput(_ tab: TabModel, services: AppServices) -> NewWorkspaceName.Tab {
        // A conversation, page or app tab's record is titled `about:blank`, a placeholder (a New
        // Tab page dragged to the sidebar named its workspace "about:blank"): only a name the tab
        // shows of its own names the workspace.
        if tab.kind == .conversation || tab.appTab != nil {
            return NewWorkspaceName.Tab(kind: .page, userName: tab.name, title: ownName(tab, services: services), pageTitle: nil, url: nil, cwd: nil)
        }
        let kind: NewWorkspaceName.Tab.Kind = switch tab.kind {
        case .pty: .terminal
        case .browser: .browser
        case .remoteTerminal: .remoteTerminal
        // A conversation or a kind this app does not know: its title still names it.
        case .conversation, .other: .terminal
        }
        let offTheRecord = tab.kind == .browser && services.cache.browserTabs.isIncognitoTab(tab.id) == true
        let pageTitle = tab.kind == .browser && !offTheRecord ? services.cache.existingBrowser(tab.id)?.tab.state.title : nil
        return NewWorkspaceName.Tab(kind: kind, userName: tab.name, title: tab.titleText, pageTitle: pageTitle,
                                    url: tab.url, cwd: tab.cwd)
    }

    /// The name a conversation, page or app tab shows of its own: its page's or app's title, its
    /// Home conversation's title or the Chief's name. Nil for an agent chat or New Tab page (named
    /// from its chat, `WorkspaceAutoNameReader`), an app with no page, and an untitled Home
    /// conversation: a generic label ("New Tab", "Home") written now would stay as the user's name.
    private static func ownName(_ tab: TabModel, services: AppServices) -> String? {
        if tab.agentSession != nil { return nil }
        if let app = tab.appTab {
            guard let provider = services.apps.pageProvider(appID: app.app, codeRouterAsPage: false) else { return nil }
            return services.pages.storeTabItem(tab, page: provider.page)?.title
        }
        if tab.page != nil { return services.pages.storeTabItem(tab)?.title }
        let title = services.home.tabTitle(for: tab)
        return title == HomeStrings.title ? nil : title
    }
}
