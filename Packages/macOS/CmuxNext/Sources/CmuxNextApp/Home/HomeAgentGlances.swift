import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextIcons
import CmuxNextTabs
import CmuxNextSidebar

/// The user's agents for Home's first-run glance, read from the app's mirror.
struct HomeAgentGlances {
    let services: AppServices

    /// The user's agents for the empty Chief conversation's glance
    /// (`HomeFirstRunView`), machine by machine in each store's workspace order:
    /// agent chat tabs, and terminals whose agent reported through a hook
    /// while the terminal lives. A chat still on its New Tab page is not an
    /// agent yet. Title and status come from `TabItemMapping`, the tab
    /// strip's own mapping, so Home says what the strip and the sidebar show.
    /// Reading this inside an `ObservationStream` tracks every value it
    /// reads (the tab records, acpmux turn states, seen records).
    var current: [HomeAgentGlance] {
        let agentTabs = services.agentTabs
        var glances: [HomeAgentGlance] = []
        for (workspace, _) in services.machines.allWorkspaces {
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                let isChat = tab.agentSession != nil
                guard isChat ? !RestoredNewTabPages.shows(tab, in: agentTabs) : tab.agent != nil && !tab.dead else { continue }
                let glance = TabItemMapping.shared.glance(tab, fallbackTitle: isChat ? AgentChatTabTitle.untitled(tab.agentSession, workspaceName: AgentChatTabTitle.workspaceName(workspace)) : Strings.untitledTerminal)
                glances.append(HomeAgentGlance(id: tab.id, title: glance.title, icon: isChat ? .agentChat : .terminal,
                                               status: glanceStatus(glance.status, working: StatusMapping.shared.isWorking(tabs: [tab])),
                                               indicator: glance.indicator, indicatorStyle: glance.style))
            }
        }
        return glances
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
