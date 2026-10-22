import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
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
/// (`chief:<home id>`: the session runs in this app's Chief home's acpmux).
///
/// With `pane` or `workspace` (#23026, `cmux agents chat new`) no workspace is
/// made: the chat tab opens in that pane (the workspace's active pane) from the
/// daemon's tree, so a workspace no window shows works too. The tab is
/// selected in its pane for when the pane is shown; focus and the shown
/// workspace stay where they are. The run's result names `tab`, `pane` and
/// `workspace`.
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
        if let target = try existingPane(invocation, services: context.services) {
            let task = try open(session: session, in: target.pane, of: target.daemon, host: host,
                                changesView: invocation.allowsViewChange, services: context.services)
            context.services.registry.track(result: task)
            return
        }
        let task = try open(session: session, name: name, key: key, cwd: cwd, host: host, services: context.services)
        context.services.registry.track(task)
    }

    /// The pane the run names (`pane`, else `workspace`'s active pane) and its daemon; nil
    /// when it names neither. Throws when the named pane or workspace is not in any tree.
    private static func existingPane(_ invocation: ActionInvocation, services: AppServices) throws -> (pane: PaneModel, daemon: DaemonService)? {
        if let id = argumentID(invocation, "pane") {
            guard let pane = services.pane(id: id) else { throw ActionFailure(message: RefusalStrings.noPaneID(id), isNotFound: true) }
            return (pane, services.machines.daemon(forPane: pane))
        }
        guard let id = argumentID(invocation, "workspace") else { return nil }
        let found = services.machines.allWorkspaces.first { workspace, _ in
            workspace.id == id || workspace.resourceID?.rawValue == id || workspace.key?.rawValue == id.lowercased()
        }
        // The workspace's most recently focused pane, as New Agent Chat's workspace target picks
        // it (AgentChatPlacement, #23016).
        guard let (workspace, daemon) = found,
              let pane = Self.lastFocusedPane(of: workspace) else {
            throw ActionFailure(message: RefusalStrings.noWorkspace(id), isNotFound: true)
        }
        return (pane, daemon)
    }

    /// The workspace's most recently focused pane; a workspace never focused (every pane at 0)
    /// gives its first screen's default pane, as before.
    private static func lastFocusedPane(of workspace: WorkspaceModel) -> PaneModel? {
        let panes = workspace.screens.flatMap(\.panes)
        if let focused = panes.max(by: { $0.focusedAt < $1.focusedAt }), focused.focusedAt > 0 { return focused }
        let screen = workspace.screens.first
        return screen?.panes.first { $0.handle == screen?.defaultPane } ?? panes.first
    }

    /// A target or string argument's id, nil when absent or empty.
    private static func argumentID(_ invocation: ActionInvocation, _ name: String) -> String? {
        let id = invocation[name]?.targetValue?.id ?? invocation[name]?.stringValue
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Opens a tab on `session` in an existing `pane` of `daemon` without showing it or moving
    /// focus (see the type), and hands back its ids.
    static func open(session: String, in pane: PaneModel, of daemon: DaemonService, host: String?,
                     changesView: Bool = false, services: AppServices) throws -> ActionResultWork {
        guard services.agentTabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
        let workspace = services.machines.allWorkspaces.first { candidate, _ in
            candidate.screens.contains { $0.panes.contains { $0 === pane } }
        }?.0
        // A store tab bound to the session (agent-session-tabs-v1); a refusal throws here.
        let pending = try services.agentTabs.open(in: pane.handle, of: daemon, session: session, linked: true, host: host)
        return Task { @MainActor in
            do {
                let created = try await pending.value()
                // Selected for when the pane is shown. A window that shows the pane's workspace
                // now keeps its tab unless the run may change the view (a person, `focus: true`).
                for window in services.windows.controllers
                where changesView || workspace == nil || window.state.workspaceID != workspace?.id {
                    window.state.selection.select(created.key, in: pane.id)
                }
                let tab = daemon.store.tab(id: created.key)
                var result: [String: ActionResultValue] = [
                    "session": .string(session), "tab": .string(tab?.resourceID?.rawValue ?? created.key),
                    "pane": .string(pane.resourceID?.rawValue ?? pane.id),
                ]
                if let workspace {
                    result["workspace"] = .string(workspace.resourceID?.rawValue ?? workspace.id)
                    if let key = workspace.key { result["workspace_key"] = .string(key.rawValue) }
                }
                return .success(result)
            } catch let refusal as AgentTabRefusal {
                return .failure(ActionWorkFailure("agent.openSessionWorkspace: \(refusal.message)"))
            } catch {
                daemon.logger.error("agent.openSessionWorkspace in pane failed: \(String(describing: error), privacy: .public)")
                return .failure(ActionWorkFailure("agent.openSessionWorkspace: \(error)"))
            }
        }
    }

    /// Starts the new workspace for `session` (see the type) and returns its
    /// work. Start Agent's Return (cx-hkat) puts its started chat in the
    /// sidebar this way too. Throws when this build has no agent page or the
    /// daemon is offline.
    @discardableResult
    static func open(session: String, name: String?, key: WorkspaceKey = .generate(), cwd: String?, host: String? = nil,
                     services: AppServices) throws -> ActionWork {
        guard services.agentTabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
        let daemon = services.daemon
        guard let connection = daemon.connection, case let repair = services.emptyWorkspaces else {
            throw ActionFailure(message: MiscHandlerStrings.daemonOffline)
        }
        let logger = daemon.logger
        // Placed like Cmd-N (`workspaces.newPlacement`): in the group of the
        // workspace the window shows, when it is in one (cx-caoh). A caller's
        // key that names a listed workspace leaves that workspace where it is.
        let windows = services.windows
        if services.machines.workspace(id: key.rawValue) == nil {
            NewWorkspacePlacements.expect(key.rawValue, in: nil, byDefault: NewWorkspacePlacements.rule(for: nil, in: windows), windows: windows)
        }
        return Task { @MainActor in
            do {
                _ = try await WorkspaceCreation.create(key, name: name, on: connection, repair: repair) { workspace in
                    try await connection.createTerminal(in: workspace, cwd: cwd)
                }
                // The workspace's first pane once the store mirrors it, found
                // by the key chosen here (as CloudHandlers finds its anchor).
                guard let pane = await mirroredPane(of: key, in: daemon.store) else {
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

    /// The first pane of workspace `key` once the store mirrors it (10 s at most).
    @MainActor static func mirroredPane(of key: WorkspaceKey, in store: DaemonStore) async -> PaneModel? {
        if let pane = firstPane(of: key, in: store) { return pane }
        // concurrency-allow: the observation task exits on cancellation; this bounds a daemon mirror race
        let mirrored = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await waitForPane(of: key, in: store) }
            group.addTask {
                // wakeup-allow: one-shot ten-second daemon mirror deadline
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        return mirrored ? firstPane(of: key, in: store) : nil
    }

    @MainActor private static func firstPane(of key: WorkspaceKey, in store: DaemonStore) -> PaneModel? {
        store.workspaces.first { $0.key == key }?.screens.first?.panes.first
    }

    @MainActor private static func waitForPane(of key: WorkspaceKey, in store: DaemonStore) async -> Bool {
        for await ready in ObservationStream({ firstPane(of: key, in: store) != nil }) where ready { return true }
        return false
    }
}
