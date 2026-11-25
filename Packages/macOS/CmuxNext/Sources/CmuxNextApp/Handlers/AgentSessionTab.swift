import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextDaemon
import Foundation

/// `agent.openSessionTab` (`cmux agent open-tab SESSION`, MCP `app_agent_open_tab`): the agent
/// chat of an EXISTING acpmux session as a tab of a pane, so an agent puts a sub-session's chat in
/// front of the user without a new workspace (`agent.openSessionWorkspace` makes one). The pane is
/// the target's (a pane, or a tab's pane; any workspace, also one no window shows), else the
/// focused pane. The tab is a workspace store tab bound to the session (agent-session-tabs-v1), so
/// it is saved and restored like any tab; closing it only detaches from the session.
///
/// A session a live tab already shows gets no second tab; the run answers that tab (a dead binding opens anew). Only a run that may change the view (the
/// person's, or `focus: true`) selects and shows the tab; a script's run adds it and leaves the
/// person's view as it is. Arguments: `session` (required), `host` (`chief:<home id>`: the session
/// runs in this app's Chief home's acpmux; an acpmux peer's name such as `huge-blue`: its chat as
/// this Mac's acpmux mirrors it (`AgentPeerSession`); absent: this Mac's).
enum AgentSessionTab {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agent.openSessionTab", run: { try open($0, context: context) })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let services = context.services
        let (session, host): (String, String?)
        do { (session, host) = try services.agentLanes.tabSession(for: invocation, localHost: services.agentTabs.localHost, sessionRequired: MiscHandlerStrings.sessionRequired) } catch { throw ActionFailure(message: error.description) }
        guard services.agentTabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
        let shows = invocation.allowsViewChange
        if let shown = liveTab(showing: session, host: host, services: services) { // its ids, and a failed reveal throws (ask-a0466e9c05)
            if shows, !services.revealTab(shown.tab.id) { throw ActionFailure(message: MiscHandlerStrings.sessionTabRevealFailed(shown.tab.resourceID?.rawValue ?? shown.tab.id)) }
            let answer = AgentSessionOpenAnswer.fields(session: session, tab: shown.tab, pane: shown.pane, workspace: services.daemon(for: shown.pane).store.workspace(containing: shown.pane.handle))
            return context.registry.track(result: Task { .success(answer) })
        }
        // A target that names nothing was refused by the lookup.
        guard let pane = context.daemonPane(invocation) else { return }
        let daemon = services.daemon(for: pane)
        let pending: AgentTabPending
        do {
            pending = try services.agentTabs.open(in: pane.handle, of: daemon, session: session, linked: true, host: host, idempotencyKey: (DaemonCommandScope.current?.nextDerivedUUID("agent-session-tab") ?? UUID()).uuidString.lowercased()) // a repeated run: the same tab
        } catch let refusal as AgentTabRefusal {
            throw ActionFailure(message: refusal.message)
        }
        // The create reply can precede tab-added. Selection follows the stand-in to the daemon tab.
        let revealed = shows && services.revealTab(pending.key, onMachine: daemon.machineID)
        let workspace = daemon.store.location(of: pane)?.workspace
        // The run answers the new tab's ids (`cmux agents chat new`, #23026), as New Agent Chat's
        // script runs do, so the caller can find the chat it put there.
        context.registry.track(result: Task { @MainActor in
            do {
                let created = try await pending.value()
                if shows, !revealed, !services.revealTab(created.key, onMachine: daemon.machineID) {
                    return .failure(ActionWorkFailure(refusal: .unavailable, reason: MiscHandlerStrings.sessionTabRevealFailed(created.key)))
                }
                daemon.logger.info("agent.openSessionTab: session \(session, privacy: .public) in tab \(created.key, privacy: .public)")
                return .success(AgentSessionOpenAnswer.fields(session: session, tab: daemon.store.tab(id: created.key), tabID: created.key, pane: pane, workspace: workspace))
            } catch is CancellationError {
                return .success(["session": .string(session)]) // the person closed the tab first
            } catch {
                daemon.logger.error("agent.openSessionTab failed: \(String(describing: error), privacy: .public)")
                return .failure(ActionWorkFailure("agent.openSessionTab", error))
            }
        })
    }

    /// The tab showing `session` of `host` (in workspace `workspace`, by key or id) that is live: a store's tab in a pane
    /// of a listed workspace. A binding that resolves to none is passed over, so the chat opens again instead.
    static func liveTab(showing session: String, host: String?, services: AppServices, in workspace: String? = nil) -> (tab: TabModel, pane: PaneModel)? {
        var live: (tab: TabModel, pane: PaneModel)?
        _ = services.agentTabs.tab(showing: session, host: host, where: { key, machine in
            live = services.locateTab(key, onMachine: machine).flatMap { found in services.daemon(for: found.1).store.workspace(containing: found.1.handle).flatMap { AgentSessionOpenAnswer.holds($0, workspace) ? found : nil } }
            return live != nil
        })
        return live
    }
}
