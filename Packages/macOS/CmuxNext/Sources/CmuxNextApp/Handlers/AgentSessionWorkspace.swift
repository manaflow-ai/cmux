import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextWorkspaceRepair
import Foundation

/// `agent.openSessionWorkspace`: a new workspace whose selected tab is the
/// agent chat of an EXISTING acpmux session. The Home Chief runs each
/// subagent it spawns this way (optchat-chief `spawn`), so the user sees
/// every subagent in the sidebar, watches its chat and tool calls, and can
/// write to it. The workspace gets a terminal in `cwd` first (a daemon
/// workspace needs a daemon tab), then the agent tab on `session`, which is
/// selected in every window. Nothing takes focus or switches workspaces.
/// Closing the tab or the workspace only detaches from the session; the
/// session ends only when someone ends it.
///
/// Arguments: `session` (required, the acpmux session id), `name` (the
/// workspace name), `key` (a caller-chosen workspace key, a lowercase UUID,
/// so the caller can rename the workspace later), `cwd` (the terminal's), `host`
/// (`chief:<home id>`: the session runs in this app's Chief home's acpmux; another machine's name, as
/// the sidebar or `acpmux ls` shows it: the session runs there), `group` (the name of the sidebar
/// group it goes in: any group of that name that can hold the row, made only when none can;
/// `acpmux new --group` sends it; another machine's chat joins that machine's group of the name).
/// A `key` that names a listed workspace opens nothing: a launcher run again finds its row. A
/// `name` that already has a row of this Mac in that group (a lane re-homed to another machine,
/// whose new session has a new key) gets the chat as a tab of that row, never a second row of the
/// same name.
enum AgentSessionWorkspace {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agent.openSessionWorkspace", run: { invocation in
            try open(invocation, context: context)
        })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let session = (invocation["session"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { throw ActionFailure(message: MiscHandlerStrings.sessionRequired) }
        let name = invocation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let given = invocation["key"]?.stringValue?.lowercased()
        let key = given.flatMap { UUID(uuidString: $0) == nil ? nil : WorkspaceKey(rawValue: $0) } ?? .generate()
        let cwd = invocation["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        // The Chief host's own acpmux runs the session (`chief:<home id>`); absent: this Mac's.
        let host = invocation["host"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        // A host that names another machine (`cmux agent open NAME --host huge-blue`): its chat opens there.
        let remote = host.flatMap(context.services.machines.remoteDaemon(named:)), group = invocation["group"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let task = try remote.map { try adopt(session: session, name: name, key: key, cwd: cwd, group: group, on: $0, services: context.services) }
            ?? open(session: session, name: name, key: key, cwd: cwd, host: host, group: group, services: context.services)
        context.services.registry.track(task)
    }

    /// Another machine's running chat in a new workspace on that machine's daemon: its agent tab is
    /// bound to `session` there (`agent-session-adopt`; a chat never leaves its machine, cx-k21v), and
    /// a chat that acts without asking shows the bypass warning on its row. A refused adopt closes
    /// the workspace. Nothing takes focus.
    private static func adopt(session: String, name: String?, key: WorkspaceKey, cwd: String?, group: String?, on daemon: DaemonService,
                              services: AppServices) throws -> ActionWork {
        try requireChatPage(services)
        guard let connection = daemon.connection, let endpoint = daemon.remoteEndpoint, let host = AgentTabStore.registryHost(of: daemon) else {
            throw ActionFailure(message: MiscHandlerStrings.daemonOffline)
        }
        let machine = services.machines.machineName(daemon.machineID) ?? daemon.machineID
        let repair = services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)
        // A caller's key that names a listed workspace already shows the session: nothing opens twice.
        if services.machines.workspace(id: key.rawValue) != nil { return Task { nil } }
        // `group`: that machine's group of the name (made when missing), once the row is listed.
        var join: (@MainActor @Sendable (String, SidebarBridge) -> Void)?
        if let group { join = { id, sidebar in AgentSessionWorkspace.join(id, group: group, sidebar: sidebar) } }
        NewWorkspacePlacements.expect(key.rawValue, in: nil, byDefault: nil, then: join, windows: services.windows)
        return Task { @MainActor in
            do {
                // The workspace, its terminal, the agent tab and the adopt, owned by `repair` while they run
                // (as WorkspaceCreation does): a failure leaves the key closing, never repaired or settling.
                // Any failure closes the workspace with its terminal and any tab, bound or not (refused, or
                // the tab or adopt reply never came); closing only detaches a session, so a lost reply after
                // a bind ends nothing. WorkspaceCreation's own close takes only an empty workspace.
                var created: WorkspaceMutationResult?
                // The terminal made here, closed with the workspace even by a daemon without batch close.
                var terminals: [WorkspaceClose.Terminal] = []
                let opened: (tab: NewConversationTabRequest.Response, adopted: AgentSessionAttachClient.Adopted) = try await repair.populating(key) {
                    try await WorkspaceCreation.withTerminal(
                        key, createWorkspace: { created = try await connection.createWorkspaceRetryingLateReplies(name: name, key: key) },
                        createTerminal: { _ in
                            guard let created else { throw DaemonError.notConnected }
                            let terminal = try await connection.createTerminal(in: created.key, cwd: cwd)
                            terminals = [(terminal.terminalID, terminal.terminalIncarnation)]
                            // One mutation id for every send: a tab the daemon made after the deadline replays.
                            let request = NewConversationTabRequest(agentSession: AgentSessionRef(host: host, hostName: machine), workspace: created.workspace,
                                                                    origin: AgentTabStore.createOrigin, mutationID: "adopt-" + key.rawValue)
                            let tab = try await DaemonConnection.retryingLateReplies(NewConversationTabRequest.command) { try await connection.request(request) }
                            return (tab: tab, adopted: try await AgentSessionAttachClient.adopt(session: session, surface: tab.surface.rawValue, endpoint: endpoint))
                        },
                        closeWorkspace: { try await closeFailedAdopt($0, terminals: terminals, on: daemon, repair: repair, services: services) })
                }
                let (tab, adopted) = (opened.tab, opened.adopted)
                AgentBypassSessions.shared.set(session, bypass: !adopted.asking)
                if let pane = await daemon.store.firstPane(mirroring: key) {
                    for window in services.windows.controllers { window.state.selection.select(tab.tabResourceID?.rawValue ?? "surface:\(tab.surface.rawValue)", in: pane.id) }
                }
                return nil
            } catch let error as AgentSessionAttachError {
                return ActionWorkFailure("agent.openSessionWorkspace: \(AgentSessionAdoptRefusal.message(code: error.code, machine: machine) ?? AgentRemoteStartRefusal(code: error.code, machine: machine, detail: error.message).userMessage)")
            } catch {
                return ActionWorkFailure("agent.openSessionWorkspace: \(error)")
            }
        }
    }

    /// Closes workspace `key` that a failed adopt made on `daemon`, with `terminals` and any tab, kept
    /// out of Recently Closed. Always on `daemon`'s live connection, never the one the adopt started
    /// on (it may be dead): while the link is down (the adopt may have failed on that drop) it waits
    /// for the next connect, and a close the link drops under is sent again once it is back. It ends
    /// on a close the daemon answers, or when `present` turns false (the machine left the app).
    @MainActor
    static func closeFailedAdopt(_ key: WorkspaceKey, terminals: [WorkspaceClose.Terminal] = [], on daemon: DaemonService,
                                 present: @escaping @MainActor @Sendable () -> Bool) async throws {
        // wakeup-allow: each pass waits on observation for a connect, then sends once; a drop is the only way round
        while true {
            for await done in ObservationStream({ daemon.isLive || !present() }) where done { break }
            guard present(), let connection = daemon.connection else { throw DaemonError.notConnected }
            do {
                try await WorkspaceClose.close(key, terminals: terminals, on: connection, reason: .sessionEnd)
                return
            } catch let error as DaemonError where closeRetries(after: error) && present() && !Task.isCancelled {
                daemon.logger.info("agent.openSessionWorkspace: closing a failed adopt's workspace lost its link (\(String(describing: error), privacy: .public)); again once connected")
            }
        }
    }

    /// Whether a failed adopt's close that failed with `error` is sent again on the next connection: the
    /// link dropped or the reply never came. A daemon's answer (`command`: refused, or the workspace is
    /// already gone) ends it.
    nonisolated static func closeRetries(after error: DaemonError) -> Bool {
        switch error {
        case .notConnected, .connectionClosed, .daemonShutdown, .connectFailed, .timedOut: true
        default: false
        }
    }

    /// ``closeFailedAdopt(_:terminals:on:present:)`` while `daemon` is one of the app's machines; a
    /// workspace still open after it is released to `repair` with the adopt's failure, as
    /// WorkspaceCreation does.
    @MainActor
    private static func closeFailedAdopt(_ key: WorkspaceKey, terminals: [WorkspaceClose.Terminal], on daemon: DaemonService,
                                         repair: EmptyWorkspaceRepair, services: AppServices) async throws {
        do {
            try await closeFailedAdopt(key, terminals: terminals, on: daemon, present: { services.machines.daemons.contains { $0 === daemon } })
        } catch {
            repair.closeFailed(key)
            throw error
        }
    }

    /// Refuses before anything is made when this build has no agent page to show the chat in (a local
    /// open and another machine's adopt alike).
    private static func requireChatPage(_ services: AppServices) throws {
        guard services.agentTabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
    }

    /// Starts the new workspace for `session` (see the type) and returns its
    /// work. Start Agent's Return (cx-hkat) puts its started chat in the
    /// sidebar this way too. Throws when this build has no agent page or the
    /// daemon is offline.
    @discardableResult
    static func open(session: String, name: String?, key: WorkspaceKey = .generate(), cwd: String?, host: String? = nil,
                     group: String? = nil, services: AppServices) throws -> ActionWork {
        try requireChatPage(services)
        let daemon = services.daemon
        guard let connection = daemon.connection, case let repair = services.emptyWorkspaces else {
            throw ActionFailure(message: MiscHandlerStrings.daemonOffline)
        }
        // A host that names no machine here is refused before anything is made (no empty workspace).
        let agentTabs = services.agentTabs
        if let refusal = AgentTabStore.hostRefusal(host, localHost: agentTabs.localHost, chiefHost: agentTabs.chiefHost, daemonIsLocal: daemon.isLocal) {
            throw ActionFailure(message: refusal)
        }
        let logger = daemon.logger
        // A caller's key that names a listed workspace already shows the
        // session (a launcher run again): nothing is opened twice.
        if services.machines.workspace(id: key.rawValue) != nil { return Task { nil } }
        let windows = services.windows
        // Every window's sidebar: each lists only its own workspaces, and the predecessor may be in any.
        if let group, let name,
           let row = windows.controllers.lazy.compactMap({ predecessor(named: name, inGroup: group, in: $0.sidebar.model.sections) }).first {
            return reuse(row, session: session, key: key, host: host, services: services)
        }
        // Placed like Cmd-N (`workspaces.newPlacement`): in the group of the
        // workspace the window shows, when it is in one (cx-caoh), then into
        // the named `group`.
        var join: (@MainActor @Sendable (String, SidebarBridge) -> Void)?
        if let group {
            join = { id, sidebar in AgentSessionWorkspace.join(id, group: group, sidebar: sidebar) }
        }
        NewWorkspacePlacements.expect(key.rawValue, in: nil, byDefault: NewWorkspacePlacements.rule(for: nil, in: windows),
                                      then: join, windows: windows)
        return Task { @MainActor in
            do {
                _ = try await WorkspaceCreation.create(key, name: name, on: connection, repair: repair) { workspace in
                    try await connection.createTerminal(in: workspace, cwd: cwd)
                }
                // The workspace's first pane once the store mirrors it, found
                // by the key chosen here (as CloudHandlers finds its anchor).
                guard let pane = await daemon.store.firstPane(mirroring: key) else {
                    logger.error("agent.openSessionWorkspace: the pane of workspace \(key.rawValue, privacy: .public) did not appear")
                    return ActionWorkFailure("agent.openSessionWorkspace: the new workspace's pane did not appear")
                }
                // A workspace store tab bound to the session (agent-session-tabs-v1),
                // so it is saved and restored with the workspace like any tab.
                let pending = try services.agentTabs.open(in: pane.handle, of: daemon, session: session, linked: true, host: host)
                let created = try await pending.value()
                // Selected wherever the workspace is shown later, never shown now.
                for window in services.windows.controllers {
                    window.state.selection.select(created.key, in: pane.id)
                }
                logger.info("agent.openSessionWorkspace: session \(session, privacy: .public) in workspace \(key.rawValue, privacy: .public) tab \(created.key, privacy: .public)")
                return nil
            } catch let refusal as AgentTabRefusal {
                return ActionWorkFailure("agent.openSessionWorkspace: \(refusal.message)")
            } catch {
                logger.error("agent.openSessionWorkspace failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("agent.openSessionWorkspace: \(error)")
            }
        }
    }

    /// The chat of a re-homed lane's new session as a tab of its predecessor's
    /// row `row`, selected there; the caller's `key` is the tab's creation key,
    /// so a launcher run again gets the same tab.
    private static func reuse(_ row: SidebarWorkspaceID, session: String, key: WorkspaceKey, host: String?,
                              services: AppServices) -> ActionWork {
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
                for window in services.windows.controllers {
                    window.state.selection.select(created.key, in: pane.id)
                }
                logger.info("agent.openSessionWorkspace: session \(session, privacy: .public) in its predecessor's workspace \(row.rawValue, privacy: .public)")
                return nil
            } catch let refusal as AgentTabRefusal {
                return ActionWorkFailure("agent.openSessionWorkspace: \(refusal.message)")
            } catch {
                return ActionWorkFailure("agent.openSessionWorkspace: \(error)")
            }
        }
    }

    /// Moves workspace `id` into the sidebar group named `name` (`group(named:accepting:in:)`), or into a
    /// new group of that name when none can hold it: the path of a row drag and of New Group, so it is one
    /// undoable sidebar edit.
    @MainActor static func join(_ id: String, group name: String, sidebar: SidebarBridge) {
        let ids = [SidebarWorkspaceID(id)]
        if let target = group(named: name, accepting: SidebarWorkspaceID(id), in: sidebar.model.sections) {
            sidebar.handle(.move(ids, toGroup: target))
            return
        }
        sidebar.groupFlow.newGroup(of: ids, name: name, byUser: false)
    }

    /// The first listed group named `name` that may hold workspace `id` (the drag's rule,
    /// `SidebarEdits.canMove`: a machine row's group holds that machine's workspaces), in any section and
    /// either organization; nil when none may. Only the first group of that name was tried before, so a
    /// row it could not hold got a new group of that name each time (nine "GUI push · lanes", 2026-10-22).
    static func group(named name: String, accepting id: SidebarWorkspaceID, in sections: [CmuxNextSidebar.SidebarSection]) -> CmuxNextSidebar.GroupID? {
        for section in sections {
            for case let .group(group) in section.nodes where group.name == name {
                if SidebarEdits.canMove([id], toGroup: group.id, in: sections) { return group.id }
            }
        }
        return nil
    }

    /// The row of this Mac titled `name` in a group named `group`: the workspace a lane of that name already
    /// has there (the launcher titles it with the lane's name; a row renamed since gets a new row, as before).
    /// Only this Mac's rows: the chat opens on this Mac's daemon, so another machine's row is never reused.
    static func predecessor(named name: String, inGroup group: String, in sections: [CmuxNextSidebar.SidebarSection]) -> SidebarWorkspaceID? {
        for section in sections {
            for case let .group(listed) in section.nodes where listed.name == group {
                if let row = listed.workspaces.first(where: { $0.title == name && $0.machineID == .local }) { return row.id }
            }
        }
        return nil
    }
}
