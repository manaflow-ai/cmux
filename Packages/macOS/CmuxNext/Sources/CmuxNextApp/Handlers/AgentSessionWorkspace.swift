import CmuxNextActions
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
/// so the caller can rename the workspace later), `cwd` (the terminal's).
enum AgentSessionWorkspace {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agent.openSessionWorkspace", run: { invocation in
            try open(invocation, context: context)
        })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let services = context.services
        let session = (invocation["session"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { throw ActionFailure(message: MiscHandlerStrings.sessionRequired) }
        guard services.agentTabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
        let daemon = services.daemon
        guard let connection = daemon.connection, case let repair = services.emptyWorkspaces else {
            throw ActionFailure(message: MiscHandlerStrings.daemonOffline)
        }
        let name = invocation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let given = invocation["key"]?.stringValue?.lowercased()
        let key = given.flatMap { UUID(uuidString: $0) == nil ? nil : WorkspaceKey(rawValue: $0) } ?? .generate()
        let cwd = invocation["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let logger = daemon.logger
        let task: ActionWork = Task { @MainActor in
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
                let pending = try services.agentTabs.open(in: pane.handle, of: daemon, session: session, linked: true)
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
        services.registry.track(task)
    }

    /// The first pane of workspace `key` once the store mirrors it (10 s at most).
    @MainActor private static func mirroredPane(of key: WorkspaceKey, in store: DaemonStore) async -> PaneModel? {
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
        for await ready in Observations({ firstPane(of: key, in: store) != nil }) where ready { return true }
        return false
    }
}
