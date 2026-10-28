import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextLayout
import Observation

extension AgentHandlers {
    /// The pane a new agent chat opens in (New Agent Chat, Add Harness…): the invocation's pane.
    /// Over a top page (Home), whose workspace is parked and shows no pane, a new workspace whose
    /// only tab is the chat (`seed`), as Cmd-I opens from a workspace (cx-bun). While the active
    /// workspace has no mounted pane yet (a settling workspace), Cmd-T's shared path repairs or
    /// creates its first usable pane and `open` runs once its controller mounts. Explicit targets
    /// still fail normally instead of switching panes.
    static func withAgentPane(_ invocation: ActionInvocation, context: AppActionContext, seed: AgentPaneSeed,
                              _ open: @escaping @MainActor (PaneController) -> Void) {
        if let pane = context.scope(invocation).pane { return open(pane) }
        guard invocation.target == nil else { return context.refuse(MiscHandlerStrings.noPane) }
        // Over a top page the parked workspace's panes never mount: a new workspace, or a refusal now.
        if context.activeWindow?.state.page != nil {
            if !openChatWorkspaceOverTopPage(invocation, context: context, seed: seed) { context.refuse(MiscHandlerStrings.noPane) }
            return
        }
        guard let workspace = context.scope(invocation).workspace else { return context.refuse(MiscHandlerStrings.noPane) }
        _ = context.registry.perform("newTab.default", invocation: invocation)
        context.registry.track(Task { @MainActor in
            let pane = try? await ControlDeadline.shared.run(
                method: "agent-pane.mount",
                deadline: .now + .seconds(10)
            ) { @MainActor in
                await Self.waitForPaneController(in: workspace, context: context)
            }
            guard let pane else {
                context.refuse(MiscHandlerStrings.noPane)
                return ActionWorkFailure(MiscHandlerStrings.noPane)
            }
            open(pane)
            return nil
        })
    }

    /// New Agent Chat that a script or agent aims at a pane or a workspace (the CLI, MCP; #23016),
    /// shown or not. The chat tab opens on the workspace store in that pane (a workspace's most
    /// recently focused one) with no window, workspace, selection or focus change, starts in
    /// `cwd` when given, and the run answers the tab, pane and workspace ids. Before, a pane no
    /// window shows was refused ("That pane is no longer open"). A person's run (context menu) and
    /// a run that asks for focus keep the shown-pane path. False when this path does not apply.
    static func openTargetedChat(_ invocation: ActionInvocation, context: AppActionContext) -> Bool {
        guard let target = invocation.target, target.kind == .pane || target.kind == .workspace else { return false }
        let services = context.services
        guard let place = AgentChatPlacement.resolve(target, services: services) else {
            services.registry.refuseNotFound(target.kind == .pane ? RefusalStrings.noPaneID(target.id) : RefusalStrings.noWorkspace(target.id))
            return true
        }
        let shown = services.paneController(for: place.pane)
        // The docked agent chat gets no strip tabs: a script aimed at it keeps New Agent Chat's
        // own placement (`NewChatPlacement`) in that pane, as before, also for a workspace target.
        if let shown, ChatColumnPlacement.resolve(from: shown, services: services) == .dockChat {
            openNewAgentChat(in: shown, invocation: invocation, context: context)
            return true
        }
        if let shown, invocation.allowsViewChange {
            guard target.kind == .workspace else { return false }
            openNewAgentChat(in: shown, invocation: invocation, context: context)
            return true
        }
        let seed = AgentPaneSeed(cwd: place.cwd(invocation["cwd"]?.stringValue))
        do {
            services.registry.track(result: try place.openTab(seed: seed, selects: shown == nil, services: services))
        } catch let failure as ActionFailure {
            services.registry.refuse(failure.message)
        } catch {
            services.registry.refuse(RefusalStrings.agentTabCreateFailed)
        }
        return true
    }

    /// A new workspace in the active window with the chat as its only tab, when that window shows
    /// a top page: the workspace under the page stays parked, and its panes never mount for a
    /// chat to open in. False when the daemon cannot hold a chat.
    private static func openChatWorkspaceOverTopPage(_ invocation: ActionInvocation, context: AppActionContext,
                                                     seed: AgentPaneSeed) -> Bool {
        let services = context.services
        let daemon = services.activeDaemon
        guard let window = context.activeWindow, services.agentTabs.canHost(on: daemon) else { return false }
        let windowID = window.state.id
        context.registry.track(Task { @MainActor in
            var spawn = WorkspaceSpawn(cwd: seed.cwd)
            spawn.firstChat = seed
            do {
                _ = try await services.windows.createWorkspace(spawn, on: daemon, into: windowID)
                return nil
            } catch {
                daemon.logger.error("agent chat workspace over a top page failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("new agent chat: \(error)")
            }
        })
        return true
    }

    @MainActor
    private static func waitForPaneController(in workspace: WorkspaceModel, context: AppActionContext) async -> PaneController? {
        // The store's panes are observable; mounted controllers are not, so
        // the mount generation stands in for them (`PaneMounts`).
        let services = context.services
        func mounted() -> PaneController? {
            workspace.screens.flatMap(\.panes).lazy.compactMap(services.paneController(for:)).first
        }
        for await isMounted in ObservationStream({ () -> Bool in
            _ = services.paneMounts.generation
            return mounted() != nil
        }) where isMounted {
            return mounted()
        }
        return nil
    }
}
