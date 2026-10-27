import CmuxNextActions
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
/// write to it. The workspace gets a terminal in `cwd` first (a daemon
/// workspace needs a daemon tab), then the agent tab on `session`, which is
/// selected in every window. Nothing takes focus or switches workspaces.
/// Closing the tab or the workspace only detaches from the session; the
/// session ends only when someone ends it.
///
/// Arguments: `session` (required, the acpmux session id), `name` (the
/// workspace name), `key` (a caller-chosen workspace key, a lowercase UUID,
/// so the caller can rename the workspace later), `cwd` (the terminal's), `host`
/// (`chief:<home id>`: the session runs in this app's Chief home's acpmux),
/// `group` (the name of the sidebar group it goes in: any group of that name
/// that can hold the row, made only when none can; `acpmux new --group` sends
/// it). A `key` that names a listed workspace opens nothing: a launcher run
/// again finds its row. A `name` that already has a row in that group (a lane
/// re-homed to another machine, whose new session has a new key) gets the
/// chat as a tab of that row, never a second row of the same name.
/// An agent's call (`callerAgentSession`) records that agent's session as
/// the opened session's lineage parent (``AgentSessionParents``), so the
/// sidebar's session tree nests the new workspace under the caller's even
/// when the session's daemon lists no lineage (a remote or older daemon).
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
        let group = invocation["group"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let parent = invocation.callerAgentSession.flatMap { caller in
            Self.callerIdentity(caller, in: context.services.agentTabs.listTabs().map {
                AgentSessionRef(host: $0.record.host, session: $0.record.session)
            })
        }
        let task = try open(session: session, name: name, key: key, cwd: cwd, host: host, group: group,
                            parent: parent, services: context.services)
        context.services.registry.track(task)
    }

    /// Resolves a caller only when every tab with its session belongs to one host. Duplicate tabs
    /// on that host are the same lineage; the same id on two hosts is intentionally ambiguous.
    @MainActor static func callerIdentity(_ caller: String, in records: [AgentSessionRef]) -> AgentSessionParents.Identity? {
        let hosts = Set(records.filter { $0.session == caller }.map(\.host))
        guard hosts.count == 1, let host = hosts.first else { return nil }
        return AgentSessionParents.identity(host: host, session: caller)
    }

    /// Starts the new workspace for `session` (see the type) and returns its
    /// work. Start Agent's Return (cx-hkat) puts its started chat in the
    /// sidebar this way too. `parent` is the session of the agent that asked
    /// (nil for a person), recorded once the chat tab opens. Throws when this
    /// build has no agent page or the daemon is offline.
    @discardableResult
    static func open(session: String, name: String?, key: WorkspaceKey = .generate(), cwd: String?, host: String? = nil,
                     group: String? = nil, parent: AgentSessionParents.Identity? = nil, services: AppServices) throws -> ActionWork {
        guard services.agentTabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
        let daemon = services.daemon
        guard let connection = daemon.connection, case let repair = services.emptyWorkspaces else {
            throw ActionFailure(message: MiscHandlerStrings.daemonOffline)
        }
        let logger = daemon.logger
        let targetHost = host ?? services.agentTabs.localHost ?? ""
        // A caller's key that names a listed workspace already shows the
        // session (a launcher run again): nothing is opened twice.
        if services.machines.workspace(id: key.rawValue) != nil { return Task { nil } }
        let windows = services.windows
        // Every window's sidebar: each lists only its own workspaces, and the predecessor may be in any.
        if let group, let name,
           let row = windows.controllers.lazy.compactMap({ predecessor(named: name, inGroup: group, in: $0.sidebar.model.sections) }).first {
            return reuse(row, session: session, key: key, host: host, parent: parent, services: services)
        }
        // Placed like Cmd-N (`workspaces.newPlacement`): in the group of the
        // workspace the window shows, when it is in one (cx-caoh), then into
        // the named `group`.
        var join: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)?
        if let group {
            join = { id, sidebar in
                guard let sidebar = sidebar as? SidebarBridge else { return }
                AgentSessionWorkspace.join(id, group: group, sidebar: sidebar)
            }
        }
        NewWorkspacePlacements.expect(key.rawValue, in: nil, byDefault: NewWorkspacePlacements.rule(for: nil, in: windows),
                                      then: join, windows: windows)
        return Task { @MainActor in
            do {
                // Waits for the terminal on a loaded host (Leo, 2026-10-21: a 5 s start deadline
                // left the workspace a bare shell, never attached): the start that lands late is
                // the one the session's tab goes beside.
                _ = try await WorkspaceCreation.create(key, name: name, on: connection, repair: repair) { workspace in
                    try await connection.createTerminalWaitingForStart(in: workspace, cwd: cwd)
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
                AgentSessionWorkspace.recordParent(parent, of: AgentSessionParents.identity(host: targetHost, session: session),
                                                     in: SidebarSessionTreeFeed.shared.recordedParents)
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

    /// Records `caller`, the session of the agent that opened `session`'s
    /// workspace, as `session`'s lineage parent. The sidebar's tree reads it
    /// only where the session's daemon lists no lineage of its own, so a
    /// daemon's `spawnedBy`/`startedBy` still wins. A person's open (no
    /// caller) records nothing.
    @MainActor static func recordParent(_ caller: AgentSessionParents.Identity?, of child: AgentSessionParents.Identity,
                                         in parents: AgentSessionParents) {
        parents.record(caller, of: child)
    }

    /// The chat of a re-homed lane's new session as a tab of its predecessor's
    /// row `row`, selected there; the caller's `key` is the tab's creation key,
    /// so a launcher run again gets the same tab.
    private static func reuse(_ row: SidebarWorkspaceID, session: String, key: WorkspaceKey, host: String?,
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
                for window in services.windows.controllers {
                    window.state.selection.select(created.key, in: pane.id)
                }
                AgentSessionWorkspace.recordParent(parent, of: AgentSessionParents.identity(host: host ?? services.agentTabs.localHost ?? "", session: session),
                                                     in: SidebarSessionTreeFeed.shared.recordedParents)
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
