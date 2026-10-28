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

    /// Resolve the host from the composer's inventory before creating any tab. This is one
    /// action path for CLI, MCP and the palette, including unknown/offline rejection.
    static func openOnHost(_ invocation: ActionInvocation, context: AppActionContext) -> Bool {
        guard let raw = invocation["host"] else { return false }
        guard let wanted = raw.targetValue?.id ?? raw.stringValue, !wanted.isEmpty else {
            context.refuse(WorkspaceVerbStrings.noMachine)
            return true
        }
        let destinations = AgentChatDestinations(services: context.services)
        let capturedByCaller = context.registry.isCapturingWork
        let task = Task { @MainActor () -> Result<[String: ActionResultValue], ActionWorkFailure> in
            let result = await createOnHost(wanted, invocation: invocation, destinations: destinations, context: context)
            if !capturedByCaller, case .failure(let failure) = result { context.registry.refuse(failure.message) }
            return result
        }
        context.registry.track(result: task)
        return true
    }

    static func createOnHost(_ wanted: String, invocation: ActionInvocation, destinations: AgentChatDestinations,
                             context: AppActionContext) async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        let rows = await destinations.load()
        guard !Task.isCancelled else { return .failure(ActionWorkFailure(WorkspaceVerbStrings.machineNotConnected)) }
        guard let destination = AgentChatDestinations.resolve(wanted, in: rows) else {
            return .failure(ActionWorkFailure(refusal: .notFound, reason: WorkspaceVerbStrings.noMachine))
        }
        guard destination.isReady else {
            return .failure(ActionWorkFailure(refusal: .unavailable, reason: WorkspaceVerbStrings.machineNotConnected))
        }
        var routed = invocation
        if case .peer(let peer) = destination.route {
            // A peer does not need a cmux workspace daemon. The tab stays in the requested
            // local pane while the Environment picker's chat.new path starts it on the peer.
            let local = invocation.target.map { AgentChatPlacement.resolve($0, services: context.services)?.daemon.isLocal == true }
                ?? context.services.activeDaemon.isLocal
            guard local else { return .failure(ActionWorkFailure(refusal: .unavailable, reason: WorkspaceVerbStrings.noMachine)) }
            routed.arguments["host"] = .string(peer)
        }
        // Capture child work synchronously inside this task, then await it here. The outer
        // CLI/MCP run must not answer before tab creation or lose the new tab's result fields.
        var failure: ActionWorkFailure?
        let captured = context.registry.capturingRun {
            let refused = context.registry.capturingRefusal {
                if case .cloud(let id) = destination.route { openCloudChat(routed, machine: id, context: context) }
                else { openLocalChat(routed, context: context) }
            }
            if let refused { failure = ActionWorkFailure(refusal: .unavailable, reason: refused) }
        }
        if let failure { return .failure(failure) }
        for work in captured.work {
            if let failure = await work.value { return .failure(failure) }
        }
        var fields: [String: ActionResultValue] = [:]
        for result in captured.results {
            switch await result.value {
            case .success(let value): fields.merge(value, uniquingKeysWith: { _, new in new })
            case .failure(let error): return .failure(error)
            }
        }
        return .success(fields)
    }

    static func openLocalChat(_ invocation: ActionInvocation, context: AppActionContext) {
        if openTargetedChat(invocation, context: context) { return }
        if let pane = context.scope(invocation).pane,
           DockedAgentChat.open(from: pane, invocation: invocation, services: context.services) { return }
        withAgentPane(invocation, context: context, seed: seed(for: invocation)) { pane in
            openNewAgentChat(in: pane, invocation: invocation, context: context)
        }
    }

    private static func openCloudChat(_ invocation: ActionInvocation, machine: String,
                                      context: AppActionContext) {
        let services = context.services
        let task: ActionResultWork = Task { @MainActor in
            do {
                guard services.cloud.isSignedIn, services.cloud.hasLoadedCurrentMachines,
                      let session = services.machines.session(machine) else {
                    return .failure(ActionWorkFailure(WorkspaceVerbStrings.machineNotConnected))
                }
                try await CloudHandlers.attached(session, invocation)
                let anchor: (id: String, pane: PaneModel)
                if let target = invocation.target {
                    guard let placement = AgentChatPlacement.resolve(target, services: services),
                          placement.daemon.machineID == session.daemon.machineID else {
                        return .failure(ActionWorkFailure(WorkspaceVerbStrings.noMachine))
                    }
                    anchor = (placement.workspace.id, placement.pane)
                } else {
                    let first = try await CloudHandlers.terminalAnchor(on: session, context)
                    anchor = (first.id, first.pane)
                }
                var requested = seed(for: invocation)
                // This tab's native remote host already routes to the Cloud machine. It must not
                // also ask that machine's acpmux for a peer of the same name.
                requested.host = nil
                let pending = try services.agentTabs.open(in: anchor.pane.handle, of: session.daemon,
                                                          seed: AgentPaneSeedSource(requested))
                let created = try await pending.value()
                if invocation.allowsViewChange, let controller = services.paneController(for: anchor.pane) {
                    controller.selectWhenReported(surface: created.surface)
                }
                return .success(["tab": .string(created.key), "pane": .string(anchor.pane.resourceID?.rawValue ?? anchor.pane.id),
                                 "workspace": .string(anchor.id)])
            } catch let failure as ActionFailure {
                return .failure(ActionWorkFailure(failure.message))
            } catch let failure as AgentTabRefusal {
                return .failure(ActionWorkFailure(failure.message))
            } catch is CancellationError {
                return .failure(ActionWorkFailure(WorkspaceVerbStrings.machineNotConnected))
            } catch {
                return .failure(ActionWorkFailure(RefusalStrings.agentTabCreateFailed))
            }
        }
        context.registry.track(result: task)
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
        let requested = seed(for: invocation)
        let seed = AgentPaneSeed(cwd: requested.host == nil ? place.cwd(requested.cwd) : requested.cwd,
                                 harness: requested.harness, model: requested.model, host: requested.host)
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
