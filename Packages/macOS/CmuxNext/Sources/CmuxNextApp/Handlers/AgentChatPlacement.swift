import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// The pane an agent chat that a script or agent asks for opens in (#23016): a pane named by id,
/// or a workspace's most recently focused pane, on any machine and whether or not a window shows
/// it. A pane no window shows has no `PaneController`, so its chat tab opens on the workspace
/// store (`AgentTabStore.open(in:of:…)`): nothing is shown, no workspace is switched, and focus
/// stays where it was.
struct AgentChatPlacement {
    let pane: PaneModel
    let workspace: WorkspaceModel
    let daemon: DaemonService

    /// Destination focus is client-local: prefer the active window's current/remembered
    /// workspace and pane, then other windows, then the daemon's last focused available pane.
    @MainActor static func destination(on daemon: DaemonService, services: AppServices) -> AgentChatPlacement? {
        let active = services.windows.active
        let windows = [active].compactMap { $0 } + services.windows.controllers.filter { $0 !== active }
        for window in windows {
            let state = window.state
            for id in [state.workspaceID].compactMap({ $0 }) + state.workspaceRecency {
                guard let workspace = daemon.store.workspace(id: id), workspace.key != nil else { continue }
                let panes = workspace.screens.flatMap(\.panes)
                let remembered = state.focus.rememberedPanes()[id]
                // The window's workspace changes before its focus topology. Never let the
                // previous workspace's pane mask this destination's remembered focus.
                let focused = state.workspaceID == id && state.focus.state.topology.workspace == id ? state.focus.state.pane : nil
                let preferred = [focused, remembered].compactMap { candidate in
                    candidate.flatMap { id in panes.first { $0.id == id } }
                }.first
                if let pane = preferred ?? panes.max(by: { $0.focusedAt < $1.focusedAt }) {
                    return AgentChatPlacement(pane: pane, workspace: workspace, daemon: daemon)
                }
            }
        }
        return daemon.store.workspaces.filter { $0.key != nil }.flatMap { workspace in
            workspace.screens.flatMap(\.panes).map { AgentChatPlacement(pane: $0, workspace: workspace, daemon: daemon) }
        }.max(by: { $0.pane.focusedAt < $1.pane.focusedAt })
    }

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

    /// The folder a new chat here starts in: the caller's, the workspace's agent folder, else the
    /// pane's selected tab's (as New Agent Chat inherits it, #16620).
    @MainActor func cwd(_ given: String?) -> String? {
        if let given, !given.isEmpty { return given }
        if let folder = workspace.agentFolder { return folder }
        let tabs = pane.tabs
        return tabs.indices.contains(pane.defaultTabIndex) ? tabs[pane.defaultTabIndex].cwd : tabs.first?.cwd
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
