import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// `agent.openSessionWorkspace`: shows the agent chat of an EXISTING acpmux
/// session. The Home Chief runs each subagent it spawns this way
/// (optchat-chief `spawn`), so the user sees every subagent in the sidebar,
/// watches its chat and tool calls, and can write to it.
///
/// A tab that shows the session already is reused (``AgentSessionWorkspacePlan``):
/// it is selected in its pane, and shown and focused only when the run may
/// change the view (a person's run, or `focus`). Else a new workspace opens
/// whose only tab is the session's chat, with no terminal: the workspace and
/// its chat tab are one creation, and a failed tab closes the half-made
/// workspace (`WorkspaceCreation.createWithFirstTab`). Nothing else takes
/// focus or switches workspaces. Closing the tab or the workspace only
/// detaches from the session; the session ends only when someone ends it.
///
/// Arguments: `session` (required, the acpmux session id), `name` (the
/// workspace name), `key` (a caller-chosen workspace key, a lowercase UUID,
/// so the caller can rename the workspace later), `cwd` (kept for older
/// callers; the chat runs in its session's own directory), `host`
/// (`chief:<home id>`: the session runs in this app's Chief home's acpmux).
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
        let task = try open(session: session, name: name, key: key, cwd: cwd, host: host,
                            focus: invocation.allowsViewChange, services: context.services)
        context.services.registry.track(task)
    }

    /// Shows `session` (see the type) and returns the work. Start Agent's
    /// Return (cx-hkat) puts its started chat in the sidebar this way too.
    /// Throws when this build has no agent page, the daemon is offline, or
    /// `host` names no host of this app.
    @discardableResult
    static func open(session: String, name: String?, key: WorkspaceKey = .generate(), cwd: String?, host: String? = nil,
                     focus: Bool = false, services: AppServices) throws -> ActionWork {
        let tabs = services.agentTabs
        guard tabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
        if case .reveal(let tab) = AgentSessionWorkspacePlan.choose(existing: tabs.tab(showing: session, host: host)) {
            reveal(tab, focus: focus, services: services)
            return Task { nil }
        }
        let daemon = services.daemon
        guard let connection = daemon.connection, let localHost = tabs.localHost, case let repair = services.emptyWorkspaces else {
            throw ActionFailure(message: MiscHandlerStrings.daemonOffline)
        }
        // A Chief subagent's tab names this app's Chief home (`chief:<home id>`); no other host.
        if let host, host != tabs.chiefHost { throw ActionFailure(message: RefusalStrings.agentTabCreateFailed) }
        _ = cwd
        let logger = daemon.logger
        // Placed like Cmd-N (`workspaces.newPlacement`): in the group of the
        // workspace the window shows, when it is in one (cx-caoh). A caller's
        // key that names a listed workspace leaves that workspace where it is.
        let windows = services.windows
        if services.machines.workspace(id: key.rawValue) == nil {
            NewWorkspacePlacements.expect(key.rawValue, in: nil, byDefault: NewWorkspacePlacements.rule(for: nil, in: windows), windows: windows)
        }
        let record = AgentSessionRef(host: host ?? localHost, hostName: tabs.localHostName, session: session)
        return Task { @MainActor in
            do {
                // The workspace's one tab: a workspace store tab bound to the session
                // (agent-session-tabs-v1), saved and restored with the workspace like any tab.
                _ = try await WorkspaceCreation.createWithFirstTab(key, name: name, on: connection, repair: repair) { created in
                    try await connection.request(NewConversationTabRequest(agentSession: record, workspace: created.workspace,
                                                                           origin: AgentTabStore.createOrigin,
                                                                           mutationID: UUID().uuidString))
                }
                logger.info("agent.openSessionWorkspace: session \(session, privacy: .public) in new workspace \(key.rawValue, privacy: .public)")
                if focus, let tab = await mirroredPane(of: key, in: daemon.store)?.tabs.first { reveal(tab.id, focus: true, services: services) }
                return nil
            } catch let refusal as AgentTabRefusal {
                return ActionWorkFailure("agent.openSessionWorkspace: \(refusal.message)")
            } catch {
                logger.error("agent.openSessionWorkspace failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("agent.openSessionWorkspace: \(error)")
            }
        }
    }

    /// Tab `tab`: shown and focused with `focus` (`tab.focus`), else only selected in its pane in
    /// every window, so nothing takes focus or switches workspaces.
    private static func reveal(_ tab: String, focus: Bool, services: AppServices) {
        if focus {
            _ = services.registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .user))
            return
        }
        guard let (model, pane) = services.locateTab(tab) else { return }
        for window in services.windows.controllers {
            window.state.selection.select(model.id, in: pane.id)
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
