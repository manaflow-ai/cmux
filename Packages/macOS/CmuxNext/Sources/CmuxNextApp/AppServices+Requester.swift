import CmuxNextActions
import CmuxNextCookieImport

extension AppServices {
    /// Who asked, among this Mac's open tabs: the agent chat whose session is `session`, else the
    /// terminal whose id is `terminal` (a run's `caller.agent_session` / `caller.terminal_id`), with its
    /// tab title, workspace and tab id. The cookie import panel and the Cloud machine request card name it.
    func requester(session: String?, terminal: String?) -> CookieImportRequester {
        var invocation = ActionInvocation()
        invocation.callerAgentSession = session
        invocation.callerTerminal = terminal
        return requester(of: invocation)
    }

    /// Who sent `invocation` (``requester(session:terminal:)``).
    func requester(of invocation: ActionInvocation) -> CookieImportRequester {
        let agentTabs = agentTabs
        let tabs = daemon.store.workspaces.flatMap { workspace in
            workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { tab in
                CookieImportCandidate(tabID: tab.id, title: tab.displayTitle, workspace: workspace.displayName,
                                      agentSession: agentTabs.sessions[agentTabs.resolve(tab.id)] ?? tab.agentSession?.session,
                                      terminalIDs: [tab.terminalID?.rawValue, tab.terminalResourceID?.rawValue].compactMap(\.self))
            }
        }
        return CookieImportRequester(invocation, among: tabs) { session in
            self.chatsFeed?.chats.first { $0.sessionID == session }.map { ($0.title, $0.preview) }
        }
    }
}
