import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextWindowRules

/// The pane an agent chat that a script or agent asks for opens in (#23016): a pane named by id,
/// or a workspace's most recently focused pane, on any machine and whether or not a window shows
/// it. A pane no window shows has no `PaneController`, so its chat tab opens on the workspace
/// store (`AgentTabStore.open(in:of:…)`): nothing is shown, no workspace is switched, and focus
/// stays where it was.
struct AgentChatPlacement {
    let pane: PaneModel
    let workspace: WorkspaceModel
    let daemon: DaemonService

    /// Destination focus is client-local: the active window's current/remembered workspace and
    /// pane, then other windows, then the daemon's last focused pane (cmux-window-rules
    /// `chat::destination`, then `chat::latest_pane`).
    @MainActor static func destination(on daemon: DaemonService, services: AppServices) -> AgentChatPlacement? {
        let rules = WindowRules()
        let active = services.windows.active
        let windows = ([active].compactMap { $0 } + services.windows.controllers.filter { $0 !== active }).map { window in
            let state = window.state
            return WindowRules.ChatWindow(workspace: state.workspaceID, recency: state.workspaceRecency,
                                          focusWorkspace: state.focus.state.topology.workspace, focusedPane: state.focus.state.pane,
                                          remembered: state.focus.rememberedPanes())
        }
        var seen = Set<String>()
        let named = windows.flatMap { [$0.workspace].compactMap { $0 } + $0.recency }.filter { seen.insert($0).inserted }
            .compactMap { daemon.store.workspace(id: $0) }
        if let found = rules.chatDestination(windows: windows, workspaces: named.map(facts)) { return placement(found, named[found.workspace], daemon) }
        let all = daemon.store.workspaces.filter { $0.key != nil }
        return rules.latestChatPane(all.map(facts)).flatMap { placement($0, all[$0.workspace], daemon) }
    }

    /// The pane `target` names (`pane_…` or a pane id, else a workspace's `ws_…`, key or id; `chat::target`).
    @MainActor static func resolve(_ target: ActionTargetRef, services: AppServices) -> AgentChatPlacement? {
        let kind = target.kind == .pane ? "pane" : target.kind == .workspace ? "workspace" : "other", all = services.machines.allWorkspaces
        guard let found = WindowRules().chatTarget(kind: kind, id: target.id, workspaces: all.map { facts($0.0) }) else { return nil }
        return placement(found, all[found.workspace].0, all[found.workspace].1)
    }

    /// `workspace` as the chat destination rules read it.
    @MainActor private static func facts(_ workspace: WorkspaceModel) -> WindowRules.ChatWorkspace {
        WindowRules.ChatWorkspace(id: workspace.id, resourceId: workspace.resourceID?.rawValue, key: workspace.key?.rawValue,
                                  panes: workspace.screens.flatMap(\.panes).map {
                                      WindowRules.ChatPane(id: $0.id, resourceId: $0.resourceID?.rawValue, focusedAt: $0.focusedAt)
                                  })
    }

    /// The placement at `found`'s pane of `workspace` (the workspace the rule's index names).
    @MainActor private static func placement(_ found: WindowRules.ChatDestination, _ workspace: WorkspaceModel, _ daemon: DaemonService) -> AgentChatPlacement? {
        workspace.screens.flatMap(\.panes).first { $0.id == found.pane }.map { AgentChatPlacement(pane: $0, workspace: workspace, daemon: daemon) }
    }

    /// The folder a new chat here starts in: the caller's, the workspace's agent folder, else the
    /// pane's selected tab's (as New Agent Chat inherits it, #16620; `chat::cwd`).
    @MainActor func cwd(_ given: String?) -> String? {
        WindowRules().chatCwd(given: given, agentFolder: workspace.agentFolder, tabs: pane.tabs.map(\.cwd), selected: pane.defaultTabIndex)
    }

    /// Opens a new chat tab seeded with `seed` on the store in this pane and answers the new
    /// tab's ids once the store created it. With `selects` (a pane no window shows) the tab is
    /// selected in the pane, so it is the one shown when someone opens the workspace; a pane a
    /// window shows keeps the tab the person looks at.
    @MainActor func openTab(seed: AgentPaneSeed, selects: Bool, services: AppServices) throws -> ActionResultWork {
        let pending: AgentTabPending
        do {
            pending = try services.agentTabs.open(in: pane.handle, of: daemon, seed: AgentPaneSeedSource(seed))
        } catch let refusal as AgentTabRefusal {
            throw ActionFailure(message: refusal.message)
        }
        let (pane, workspace) = (pane, workspace)
        return Task { @MainActor in
            do {
                let created = try await pending.value()
                if selects {
                    for window in services.windows.controllers { window.state.selection.select(created.key, in: pane.id) }
                }
                var result: [String: ActionResultValue] = [
                    "tab": .string(created.key),
                    "pane": .string(pane.resourceID?.rawValue ?? pane.id),
                    "workspace": .string(workspace.resourceID?.rawValue ?? workspace.id),
                ]
                if let key = workspace.key { result["workspace_key"] = .string(key.rawValue) }
                return .success(result)
            } catch let refusal as AgentTabRefusal {
                return .failure(ActionWorkFailure(refusal.message))
            } catch {
                return .failure(ActionWorkFailure(RefusalStrings.agentTabCreateFailed))
            }
        }
    }

    /// A local or acpmux-peer destination remains available while the window shows Cloud.
    /// Explicit pane/workspace targets are checked by the caller and never retargeted here.
    @MainActor static func openLocalChat(_ invocation: ActionInvocation, context: AppActionContext) async
        -> Result<[String: ActionResultValue], ActionWorkFailure> {
        let services = context.services, daemon = services.machines.local
        if AgentChatPlacement.destination(on: daemon, services: services) == nil {
            _ = await services.windows.createWorkspace(on: daemon, into: context.activeWindow?.state.id)
        }
        guard let placement = AgentChatPlacement.destination(on: daemon, services: services) else {
            return .failure(ActionWorkFailure(refusal: .unavailable, reason: WorkspaceVerbStrings.noMachine))
        }
        return await placement.openChat(invocation, peer: AgentHandlers.seed(for: invocation).host, context: context)
    }

    /// The same store creation and reveal path for a chosen local pane or a Cloud pane.
    @MainActor func openChat(_ invocation: ActionInvocation, peer: String?, context: AppActionContext) async
        -> Result<[String: ActionResultValue], ActionWorkFailure> {
        do {
            var requested = AgentHandlers.seed(for: invocation)
            requested.host = peer
            if peer == nil { requested.cwd = cwd(requested.cwd) }
            let pending = try context.services.agentTabs.open(in: pane.handle, of: daemon,
                                                              seed: AgentPaneSeedSource(requested))
            let created = try await pending.value()
            if invocation.allowsViewChange {
                CloudHandlers.reveal(created.surface, in: pane, workspaceID: workspace.id, context)
            }
            return .success(["tab": .string(created.key), "pane": .string(pane.resourceID?.rawValue ?? pane.id),
                             "workspace": .string(workspace.id)])
        } catch let failure as AgentTabRefusal {
            return .failure(ActionWorkFailure(failure.message))
        } catch {
            return .failure(ActionWorkFailure(RefusalStrings.agentTabCreateFailed))
        }
    }
}
