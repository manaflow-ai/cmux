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
/// A session a tab already shows gets no second tab. Only a run that may change the view (the
/// person's, or `focus: true`) selects and shows the tab; a script's run adds it and leaves the
/// person's view as it is. Arguments: `session` (required), `host` (`chief:<home id>`: the session
/// runs in this app's Chief home's acpmux; an acpmux peer's name such as `huge-blue`: its chat as
/// this Mac's acpmux mirrors it (`AgentPeerSession`); absent: this Mac's).
enum AgentSessionTab {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agent.openSessionTab", run: { try open($0, context: context) })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws {
        var session = (invocation["session"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { throw ActionFailure(message: MiscHandlerStrings.sessionRequired) }
        var host = invocation["host"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let services = context.services
        // A peer's chat opens as the session this Mac's acpmux mirrors (the tab binds here, never there).
        if let peer = host, !peer.hasPrefix(ChiefHomeAcpmux.hostPrefix), peer != services.agentTabs.localHost {
            switch AgentLaneStore.shared.lanes.values.peerSession(session, on: peer) {
            case .session(let mirrored): (session, host) = (mirrored, nil)
            case .unknownSession: throw ActionFailure(message: MiscHandlerStrings.noPeerSession(session, peer))
            case .ambiguous: throw ActionFailure(message: MiscHandlerStrings.ambiguousPeerSession(session, peer))
            case .notAPeer: break // the tab's host check refuses it with its own reason
            }
        }
        guard services.agentTabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
        let shows = invocation.allowsViewChange
        if let shown = services.agentTabs.tab(showing: session, host: host) {
            if shows { _ = services.revealTab(shown) }
            return
        }
        // A target that names nothing was refused by the lookup.
        guard let pane = context.daemonPane(invocation) else { return }
        let daemon = services.daemon(for: pane)
        let pending: AgentTabPending
        do {
            pending = try services.agentTabs.open(in: pane.handle, of: daemon, session: session, linked: true, host: host)
        } catch let refusal as AgentTabRefusal {
            throw ActionFailure(message: refusal.message)
        }
        let logger = daemon.logger
        let workspace = services.machines.allWorkspaces.first { candidate, _ in
            candidate.screens.contains { $0.panes.contains { $0 === pane } }
        }?.0
        // The run answers the new tab's ids (`cmux agents chat new`, #23026), as New Agent Chat's
        // script runs do, so the caller can find the chat it put there.
        context.registry.track(result: Task { @MainActor in
            do {
                let created = try await pending.value()
                if shows { _ = services.revealTab(created.key) }
                logger.info("agent.openSessionTab: session \(session, privacy: .public) in tab \(created.key, privacy: .public)")
                var result: [String: ActionResultValue] = [
                    "session": .string(session),
                    "tab": .string(daemon.store.tab(id: created.key)?.resourceID?.rawValue ?? created.key),
                    "pane": .string(pane.resourceID?.rawValue ?? pane.id),
                ]
                if let workspace {
                    result["workspace"] = .string(workspace.resourceID?.rawValue ?? workspace.id)
                    if let key = workspace.key { result["workspace_key"] = .string(key.rawValue) }
                }
                return .success(result)
            } catch is CancellationError {
                return .success(["session": .string(session)]) // the person closed the tab first
            } catch {
                logger.error("agent.openSessionTab failed: \(String(describing: error), privacy: .public)")
                return .failure(ActionWorkFailure("agent.openSessionTab", error))
            }
        })
    }
}
