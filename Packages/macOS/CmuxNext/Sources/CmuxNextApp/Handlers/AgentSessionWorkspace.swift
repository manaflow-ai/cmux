import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

/// `agent.openSessionWorkspace`: a new workspace whose selected tab is the
/// agent chat of an EXISTING acpmux session. The Home Chief runs each
/// subagent it spawns this way (optchat-chief `spawn`), so the user sees
/// every subagent in the sidebar, watches its chat and tool calls, and can
/// write to it. The agent tab on `session` is the workspace's first and only
/// tab, selected in every window; no terminal is made (Leo, 2026-10-28: "we
/// don't want to just be seeing these bare terminals"). Nothing takes focus or
/// switches workspaces.
/// Closing the tab or the workspace only detaches from the session; the
/// session ends only when someone ends it.
///
/// Arguments: ``AgentSessionWorkspaceRequest``.
/// A `key` that names a listed workspace opens nothing: a launcher run again finds its row.
/// A `name` that already has a row in that group (a lane
/// re-homed to another machine, whose new session has a new key) gets the
/// chat as a tab of that row, never a second row of the same name.
/// An agent's call (`callerAgentSession`) records that agent's session as
/// the opened session's lineage parent (``AgentSessionParents``), so the
/// sidebar's session tree nests the new workspace under the caller's even
/// when the session's daemon lists no lineage (a remote or older daemon).
enum AgentSessionWorkspace {
    /// How long an agent-opened workspace keeps asking for its create and first chat tab through late
    /// daemon replies (one budget for both): a Chief session may be starting on a busy host.
    static let firstTabBudget: Duration = .seconds(120)

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agent.openSessionWorkspace", run: { invocation in
            try open(invocation, context: context)
        })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let request = try AgentSessionWorkspaceRequest(invocation, sessionRequired: MiscHandlerStrings.sessionRequired)
        let parent = invocation.callerAgentSession.flatMap { caller in
            AgentSessionParents.callerIdentity(caller, in: context.services.agentTabs.listTabs().map {
                AgentSessionRef(host: $0.record.host, session: $0.record.session)
            })
        }
        let session: String // the chat's acpmux id, never its name or harness session id (AgentLaneStore.localSessionID)
        do { session = try AgentLaneStore.shared.localSessionID(request.session, host: request.host, localHost: context.services.agentTabs.localHost) } catch { throw ActionFailure(message: error.description) }
        let task = try open(session: session, name: request.name, defaultName: request.defaultName, key: request.key, cwd: request.cwd,
                            host: request.host, group: request.group, top: request.top, focus: invocation.allowsViewChange, parent: parent,
                            services: context.services)
        context.services.registry.track(task)
    }

    /// Starts the new workspace for `session` (see the type) and returns its
    /// work. Start Agent's Return (cx-hkat) puts its started chat in the
    /// sidebar this way too. `parent` is the session of the agent that asked
    /// (nil for a person), recorded once the chat tab opens. Throws when this
    /// build has no agent page or the daemon is offline.
    @discardableResult
    static func open(session: String, name: String?, defaultName: String? = nil, key: WorkspaceKey = .generate(), cwd: String?, host: String? = nil,
                     group: String? = nil, top: Bool = false, focus: Bool = false, parent: AgentSessionParents.Identity? = nil,
                     services: AppServices,
                     beforeFirstTab: (@MainActor @Sendable () async -> Void)? = nil) throws -> ActionWork {
        guard services.agentTabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
        let daemon = services.daemon
        guard let connection = daemon.connection, case let repair = services.emptyWorkspaces else {
            throw ActionFailure(message: MiscHandlerStrings.daemonOffline)
        }
        let logger = daemon.logger
        let targetHost = host ?? services.agentTabs.localHost ?? ""
        // A caller's key that names a listed workspace already shows the
        // session (a launcher run again), or its stand-in (the key's first run in flight): nothing is opened twice.
        if services.machines.workspace(id: key.rawValue) != nil || daemon.store.workspaces.contains(where: { $0.key == key }) { return Task { nil } }
        let windows = services.windows
        // Every window's sidebar: each lists only its own workspaces, and the predecessor may be in any.
        if let group, let name,
           let row = SidebarEdits.predecessor(named: name, inGroup: group, inEach: windows.controllers.map(\.sidebar.model.sections)) {
            return reuse(row, session: session, key: key, host: host, focus: focus, parent: parent, services: services)
        }
        let placed = expectPlacement(key.rawValue, group: group, top: top, parent: parent, windows: windows)
        // The lineage parent before the row lists, so the row nests under its caller from its first frame, never moves under it later.
        SidebarSessionTreeFeed.shared.recordedParents.record(parent, of: AgentSessionParents.identity(host: targetHost, session: session))
        // No group: workspace and chat show now (P4) with Cmd-N's pending row at their slot, in a window whose space lists them (never drawn elsewhere first).
        let tabs = services.agentTabs, machine = MachineID(daemon.machineID), shownName = name ?? defaultName ?? SidebarMapping.nextWorkspaceName(in: daemon.store, reserved: PendingWorkspaceRows.shared.reservedNames(on: machine) { services.workspace(id: $0) != nil }), membership = WindowProfiles.membership(services.machines)
        let window = (group == nil && tabs.showsWorkspaceAtOnce(on: daemon) && AgentTabStore.hostRefusal(host, localHost: tabs.localHost, chiefHost: tabs.chiefHost, daemonIsLocal: daemon.isLocal) == nil ? windows.registry.value.mostRecentOpen() : nil).flatMap { window in membership.flatMap { membership in daemon.store.registryID.map { membership.contains(.init(session: $0, key: key.rawValue), in: windows.controller(for: window)?.state.profileID ?? .defaultProfile) } } ?? true ? window : nil }
        let instant = window.flatMap { window in PendingWorkspaceRows.shared.add(creating: key.rawValue, window: window, machine: machine, name: shownName, opensPage: true, slot: placed.slot, byDefault: placed.rule, unpinned: true); return tabs.showWorkspace(key, name: shownName, index: nil, cwd: nil, token: nil, session: (session, host, true), firstTabKeyed: true, on: daemon, repair: repair) }
        return Task { @MainActor in
            do {
                // A Chief session may be starting on a busy host. Keep one generous deadline for
                // workspace creation and its first chat tab; abandoning the tab after the short
                // control deadline leaves the daemon's late about:blank commit as a bare row.
                let giveUp = ContinuousClock.now + Self.firstTabBudget
                // The session's chat is the workspace's first tab: a workspace store tab bound to
                // the session (agent-session-tabs-v1), saved and restored with the workspace like any
                // tab. No terminal first: one running `acpmux attach` landed as a bare "~" shell
                // whenever its start missed the deadline (Leo, 2026-10-21 and 2026-10-28).
                if let instant { do { _ = try await instant.confirm(giveUp) } catch { windows.forgetCreate(key.rawValue); throw error } }
                let tab = if let instant { tabs.resolve(instant.tabKey) } else {
                    try await WorkspaceCreation.createWithFirstTab(key, name: name ?? defaultName, on: connection, repair: repair,
                                                                   giveUp: giveUp) { created in
                        await beforeFirstTab?()
                        return try await WorkspaceCreation.sessionTab(session, in: created, host: host, linked: true,
                                                                      mutationID: created.firstChatTabMutationID, until: giveUp, on: daemon, tabs: tabs)
                    }
                }
                // The workspace's first pane once the store mirrors it, found
                // by the key chosen here (as CloudHandlers finds its anchor).
                guard let pane = await daemon.store.firstPane(mirroring: key) else {
                    logger.error("agent.openSessionWorkspace: the pane of workspace \(key.rawValue, privacy: .public) did not appear")
                    return ActionWorkFailure("agent.openSessionWorkspace: the new workspace's pane did not appear")
                }
                // Selected wherever the workspace is shown later, never shown now.
                if focus {
                    for window in services.windows.controllers {
                        window.state.selection.select(tab, in: pane.id)
                    }
                }
                logger.info("agent.openSessionWorkspace: session \(session, privacy: .public) in workspace \(key.rawValue, privacy: .public) tab \(tab, privacy: .public)")
                return nil
            } catch let refusal as AgentTabRefusal {
                return ActionWorkFailure("agent.openSessionWorkspace: \(refusal.message)")
            } catch {
                logger.error("agent.openSessionWorkspace failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("agent.openSessionWorkspace: \(error)")
            }
        }
    }

    /// Registers the sidebar placement of new workspace `id`: into the named `group` alone, else below the caller's
    /// grouped row, else like Cmd-N (`workspaces.newPlacement`, cx-caoh); `top` first below Home. A named group is the
    /// row's only place: Cmd-N's slot in the window's current group first, then a move across to `group`, showed every
    /// agent's session in the wrong group for a moment (Leo, 2026-11-01: "it looks really odd when they pop up into some
    /// existing group on the sidebar as a workspace and then go to wherever they're supposed to go to").
    /// Returns the slot and the default rule it registered (a stand-in's pending row takes them).
    @discardableResult
    @MainActor static func expectPlacement(_ id: String, group: String?, top: Bool, parent: AgentSessionParents.Identity?,
                                           windows: WindowManager) -> (slot: WorkspaceSlot?, rule: NewWorkspaceDefaultSlot?) {
        var join: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)?
        if let group {
            PendingWorkspaceRows.shared.groupJoins.hold(id) // listed loose by the daemon, joined a hop later: shown once joined
            join = { id, sidebar in
                guard let sidebar = sidebar as? SidebarBridge else { return }
                AgentSessionWorkspace.join(id, group: group, sidebar: sidebar)
            }
        }
        let own = group == nil && !top ? AgentSessionParents.workspace(of: parent, in: windows.services.machines.allWorkspaces.map { $0.0 }) : nil
        let slot = own.flatMap { WorkspaceSlot.belowGrouped($0, in: windows.controllers.flatMap { $0.sidebar.model.sections }) }
        let rule = top ? NewWorkspaceDefaultSlot(placement: .top, current: nil, named: true) : NewWorkspacePlacements.rule(for: nil, in: windows)
        NewWorkspacePlacements.expect(id, in: nil, slot: slot, byDefault: group == nil ? rule : nil, then: join, windows: windows)
        return (slot, group == nil ? rule : nil)
    }

    /// The chat of a re-homed lane's new session as a tab of its predecessor's
    /// row `row`, selected there; the caller's `key` is the tab's creation key,
    /// so a launcher run again gets the same tab.
    private static func reuse(_ row: SidebarWorkspaceID, session: String, key: WorkspaceKey, host: String?, focus: Bool,
                              parent: AgentSessionParents.Identity?, services: AppServices) -> ActionWork {
        let daemon = services.daemon
        let logger = daemon.logger
        return Task { @MainActor in
            do {
                guard let pane = await daemon.store.firstPane(mirroring: WorkspaceKey(rawValue: row.rawValue)) else {
                    return ActionWorkFailure("agent.openSessionWorkspace: the pane of workspace \(row.rawValue) did not appear")
                }
                let pending = try services.agentTabs.open(in: pane.handle, of: daemon, session: session, linked: true, host: host,
                                                          idempotencyKey: key.rawValue)
                let created = try await pending.value()
                if focus {
                    for window in services.windows.controllers {
                        window.state.selection.select(created.key, in: pane.id)
                    }
                }
                SidebarSessionTreeFeed.shared.recordedParents.record(parent, of: AgentSessionParents.identity(host: host ?? services.agentTabs.localHost ?? "", session: session))
                logger.info("agent.openSessionWorkspace: session \(session, privacy: .public) in its predecessor's workspace \(row.rawValue, privacy: .public)")
                return nil
            } catch let refusal as AgentTabRefusal {
                return ActionWorkFailure("agent.openSessionWorkspace: \(refusal.message)")
            } catch {
                return ActionWorkFailure("agent.openSessionWorkspace: \(error)")
            }
        }
    }

    /// Moves workspace `id` into the sidebar group named `name` (`SidebarEdits.group(named:accepting:in:)`), or into a
    /// new group of that name when none can hold it: the path of a row drag and of New Group, so it is one
    /// undoable sidebar edit.
    @MainActor static func join(_ id: String, group name: String, sidebar: SidebarBridge) {
        let ids = [SidebarWorkspaceID(id)]
        let machine = sidebar.services.machines.daemon(forWorkspace: id).map { MachineID($0.machineID) } // its row is held out of the list
        if let target = SidebarEdits.group(named: name, accepting: SidebarWorkspaceID(id), in: sidebar.model.sections, machine: machine) {
            sidebar.handle(.move(ids, toGroup: target))
            return
        }
        // Outer spaces are not part of the label.
        sidebar.groupFlow.newGroup(of: ids, name: name.trimmingCharacters(in: .whitespacesAndNewlines), byUser: false)
    }
}
