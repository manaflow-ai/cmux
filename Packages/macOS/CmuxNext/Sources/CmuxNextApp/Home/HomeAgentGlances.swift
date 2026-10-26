import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextIcons
import CmuxNextTabs
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextAgentActivity
import CmuxNextOracle
import CryptoKit
import Foundation
#endif

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

#if DEBUG || CMUX_BENCH_HOOKS
extension AppServices {
    /// The oracle's `agents` facet (p15-oracle-043), from model values in one main-actor turn: every agent chat tab
    /// the trees list with its record's session, acpmux's lane for that session (`lane`, the app's watch mirror)
    /// and the composer text the tab store keeps for a new chat, as its sha256; then every Home Messages view (a
    /// window's Home top page, a Home tab, the docked Home) and the conversation it shows. No disk and no acpmux
    /// request; O(panes + tabs + windows).
    func oracleAgents(lane: (String) -> AgentActivityLane?) -> OracleAgentsFacet.Reading {
        let drafts = madeAgentTabs?.unsentDrafts
        let homeTabs = (pages.provider(.homeTab) as? HomePageTab)?.tabs ?? []
        let docks = (pages.provider(.homeDock) as? HomeDockTab)?.messagesViews ?? []
        let homeViews = Dictionary((homeTabs + docks).map { ($0.key, $0.view) }, uniquingKeysWith: { first, _ in first })
        let homePages: Set<String> = [InternalPageID.homeTab.rawValue, InternalPageID.homeDock.rawValue]
        var reading = OracleAgentsFacet.Reading(sessions: [], home: [])
        for (workspace, _) in machines.allWorkspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                for tab in pane.tabs {
                    if let record = tab.agentSession {
                        reading.sessions.append(Self.oracleSession(tab: tab.id, workspace: workspace.resourceID?.rawValue ?? workspace.id,
                                                                   record: record, lane: record.session.flatMap(lane),
                                                                   draft: drafts?.draft(for: tab.id)))
                    } else if let page = tab.page, homePages.contains(page) {
                        // A Home tab not shown yet has no view: it shows no conversation.
                        let view = pages.storeKey(of: tab.id).flatMap { homeViews[$0] }
                        reading.home.append(OracleAgentsFacet.HomePage(tab: tab.id, conversation: view?.shown?.rawValue))
                    }
                }
                for key in pages.tabIDs(in: pane.id) {
                    guard let view = homeViews[key] else { continue }
                    reading.home.append(OracleAgentsFacet.HomePage(tab: key, conversation: view.shown?.rawValue))
                }
            }
        }
        for controller in windows.controllers where controller.state.page == .home {
            let page = controller.topPages.views[.home] as? TopHomePageView
            reading.home.append(OracleAgentsFacet.HomePage(window: controller.state.id, conversation: page?.shown?.rawValue))
        }
        return reading
    }

    /// One agent chat tab's row: its record's session and harness (else the lane's), acpmux's lane, and `draft`
    /// only as its sha256 (the schema's `derive: sha256`).
    static func oracleSession(tab: String, workspace: String?, record: AgentSessionRef, lane: AgentActivityLane?,
                              draft: String?) -> OracleAgentsFacet.Session {
        let digest = draft.map { text in "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        return OracleAgentsFacet.Session(
            tab: tab, workspace: workspace, session: record.session, agent: record.harness ?? lane?.harness,
            lane: lane.map { OracleAgentsFacet.Session.Lane(state: $0.state.rawValue, turns: $0.turnCount, pendingPermissions: $0.pendingPermissions) },
            draftSha256: digest)
    }
}
#endif
