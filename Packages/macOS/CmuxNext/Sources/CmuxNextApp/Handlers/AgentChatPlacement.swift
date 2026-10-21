import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// The pane an agent chat that a script or agent asks for opens in (#23016): a pane named by id,
/// or a workspace's most recently focused pane, on any machine and whether or not a window shows
/// it. A pane no window shows has no `PaneController`, so its chat tab opens on the workspace
/// store (``AgentTabStore/open(in:of:session:seed:newTab:spare:linked:adopt:host:idempotencyKey:split:)``):
/// nothing is shown, no workspace is switched, and focus stays where it was.
struct AgentChatPlacement {
    let pane: PaneModel
    let workspace: WorkspaceModel
    let daemon: DaemonService

    /// The pane `target` names (`pane_…` or a pane id, else a workspace's `ws_…`, key or id).
    @MainActor static func resolve(_ target: ActionTargetRef, services: AppServices) -> AgentChatPlacement? {
        for (workspace, daemon) in services.machines.allWorkspaces {
            let panes = workspace.screens.flatMap(\.panes)
            switch target.kind {
            case .pane:
                if let pane = panes.first(where: { $0.id == target.id || $0.resourceID?.rawValue == target.id }) {
                    return AgentChatPlacement(pane: pane, workspace: workspace, daemon: daemon)
                }
            case .workspace:
                guard [workspace.id, workspace.resourceID?.rawValue, workspace.key?.rawValue].contains(target.id) else { continue }
                guard let pane = panes.max(by: { $0.focusedAt < $1.focusedAt }) else { return nil }
                return AgentChatPlacement(pane: pane, workspace: workspace, daemon: daemon)
            default:
                return nil
            }
        }
        return nil
    }

    /// Whether a window shows the pane (it then has a controller and the normal path applies).
    @MainActor func isShown(_ services: AppServices) -> Bool {
        services.paneController(for: pane) != nil
    }

    /// The folder a new chat here starts in: the caller's, the workspace's agent folder, else the
    /// pane's selected tab's (as New Agent Chat inherits it, #16620).
    @MainActor func cwd(_ given: String?) -> String? {
        if let given, !given.isEmpty { return given }
        if let folder = workspace.agentFolder { return folder }
        let tabs = pane.tabs
        return tabs.indices.contains(pane.defaultTabIndex) ? tabs[pane.defaultTabIndex].cwd : tabs.first?.cwd
    }

    /// Opens a chat tab on the store in this pane (a new chat with `seed`, or `session`'s chat)
    /// and answers the new tab's ids once the store created it. The tab is selected only in a
    /// pane no window shows, so a person looking at the pane keeps the tab they look at.
    @MainActor func openTab(session: String? = nil, seed: AgentPaneSeed? = nil, host: String? = nil,
                            services: AppServices) throws -> ActionResultWork {
        let pending: AgentTabPending
        do {
            pending = try services.agentTabs.open(in: pane.handle, of: daemon, session: session,
                                                  seed: seed.map { AgentPaneSeedSource($0) },linked: session != nil, host: host)
        } catch let refusal as AgentTabRefusal {
            throw ActionFailure(message: refusal.message)
        }
        let shown = isShown(services)
        let (pane, workspace) = (pane, workspace)
        return Task { @MainActor in
            do {
                let created = try await pending.value()
                if !shown {
                    for window in services.windows.controllers { window.state.selection.select(created.key, in: pane.id) }
                }
                var result: [String: ActionResultValue] = [
                    "tab": .string(created.key),
                    "pane": .string(pane.resourceID?.rawValue ?? pane.id),
                    "workspace": .string(workspace.resourceID?.rawValue ?? workspace.id),
                    "shown": .bool(shown),
                ]
                if let key = workspace.key { result["workspace_key"] = .string(key.rawValue) }
                if let session { result["session"] = .string(session) }
                return .success(result)
            } catch let refusal as AgentTabRefusal {
                return .failure(ActionWorkFailure(refusal.message))
            } catch {
                return .failure(ActionWorkFailure(RefusalStrings.agentTabCreateFailed))
            }
        }
    }
}
