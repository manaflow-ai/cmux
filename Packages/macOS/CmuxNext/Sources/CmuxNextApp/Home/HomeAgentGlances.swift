import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextIcons
import CmuxNextTabs
import CmuxNextSidebar

/// The user's agents for Home's first-run glance, read from the app's mirror.
struct HomeAgentGlances {
    let services: AppServices

    /// One workspace's agents for the empty Chief conversation's glance (`HomeFirstRunView`): agent chat tabs, and
    /// terminals whose agent reported through a hook while the terminal lives. A chat still on its New Tab page is not
    /// an agent yet. Title and status come from `TabItemMapping`, the strip's own mapping, so Home says what it shows.
    func glances(in workspace: WorkspaceModel) -> [HomeAgentGlance] {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab -> HomeAgentGlance? in
            let isChat = tab.agentSession != nil
            guard isChat ? !RestoredNewTabPages.shows(tab, in: services.agentTabs) : tab.agent != nil && !tab.dead else { return nil }
            let glance = TabItemMapping.shared.glance(tab, fallbackTitle: isChat ? AgentChatTabTitle.untitled(tab.agentSession, workspaceName: AgentChatTabTitle.workspaceName(workspace)) : Strings.untitledTerminal)
            let status = glanceStatus(glance.status, working: StatusMapping.shared.isWorking(tabs: [tab]))
            return HomeAgentGlance(id: tab.id, title: glance.title, icon: isChat ? .agentChat : .terminal, status: status, indicator: glance.indicator, indicatorStyle: glance.style)
        }
    }

    /// Each workspace's agents while `shows`, machine by machine in each store's workspace order (nil while not: then no
    /// tab is read). One observation for each workspace: a tab that comes, goes or changes reads its own workspace again.
    func feed(while shows: @escaping @MainActor @Sendable () -> Bool) -> ObservedItemsFeed<WorkspaceModel, [HomeAgentGlance]> {
        ObservedItemsFeed(list: { [services] in shows() ? services.machines.allWorkspaces.map { $0.0 } : nil },
                          id: { "\(ObjectIdentifier($0))" }, item: { [services] in HomeAgentGlances(services: services).glances(in: $0) })
    }

    /// The strip's status of an agent's tab as the glance's word: waiting
    /// on the user, an unseen failure or finished turn, else working or idle.
    func glanceStatus(_ status: TabStatus, working: Bool) -> HomeAgentGlance.Status {
        switch status {
        case .needsInput: .needsYou
        case .failure: .failed
        case .success: .done
        case .none: working ? .working : .idle
        }
    }
}

extension HomeAgentGlances {
    /// Only mirror reads: no new PR queries, timers or hidden-conversation work.
    func starters(agents: [HomeAgentGlance], badges: [WorkspaceID: SidebarPullRequestBadge]) -> HomeStarterContext {
        let workspaces = services.machines.allWorkspaces.map { $0.0 }.filter { $0.kind != "home" && !$0.isProvisional }
        let requests = workspaces.flatMap { badges[WorkspaceID($0.id)]?.items ?? [] }
            .filter { $0.state != .closed && $0.state != .merged }
        return HomeStarterContext(workspaces: workspaces.map(\.displayName),
                                  working: agents.filter { $0.status == .working }.map(\.title),
                                  failures: agents.filter { $0.status == .failed }.map(\.title)
                                    + requests.filter { $0.state == .failing }.map { "\($0.repository)#\($0.number)" },
                                  pullRequests: requests.map { "\($0.repository)#\($0.number)" })
    }
}
