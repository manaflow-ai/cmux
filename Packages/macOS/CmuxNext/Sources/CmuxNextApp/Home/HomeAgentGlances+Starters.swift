import CmuxNextHome
import CmuxNextSidebar

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
