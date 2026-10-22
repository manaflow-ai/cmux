import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextIcons
import CmuxNextTabs

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
                let item = TabItemMapping.shared.item(tab, fallbackTitle: isChat ? AgentChatTabTitle.untitled(tab.agentSession, workspaceName: AgentChatTabTitle.workspaceName(workspace)) : Strings.untitledTerminal)
                glances.append(HomeAgentGlance(id: tab.id, title: item.title, icon: isChat ? .agentChat : .terminal,
                                               status: glanceStatus(item.status, working: StatusMapping.shared.isWorking(tabs: [tab])),
                                               indicator: item.indicator, indicatorStyle: item.busyStyle))
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
