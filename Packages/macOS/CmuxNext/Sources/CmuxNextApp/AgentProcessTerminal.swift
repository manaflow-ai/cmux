import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// A background task's terminal (`chat.processTerminal`, background-task-terminal-DESIGN.md): the
/// viewer runs in a new terminal tab of the column right of the chat, the column the chat's diff
/// and preview open in, selected there; with no column there it opens in the chat's pane and
/// moves into a new column (``AgentBesidePlacement``). Only a chat on this Mac's daemon: the
/// viewer reads this Mac's acpmux.
///
/// The viewer is spawned with `create-terminal`, the one daemon command that runs an argv: `new-tab`
/// takes none and dropped it, so the tab ran a bare shell (an empty terminal; Leo 2026-10-21).
@MainActor
struct AgentProcessTerminal {
    let services: AppServices

    /// `move-tab`'s index for "after the last tab" (the daemon clamps it).
    private static let appendIndex = 1 << 20

    /// Opens `viewer` beside chat tab `chat`; false when the chat is not found or not on this Mac.
    func open(_ viewer: AgentPaneProcessViewer, beside chat: String) -> Bool {
        guard let (tab, chatPane) = services.locateTab(chat, onMachine: services.machines.local.machineID) else { return false }
        let daemon = services.machines.daemon(forTab: tab)
        guard daemon.isLocal, let connection = daemon.connection else { return false }
        let store = daemon.store
        let target = Self.besidePane(of: chatPane, in: store)
        let pane = target ?? chatPane
        guard let workspace = services.workspaceKey(of: pane) else { return false }
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: chat), origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = target == nil
        let services = services
        let handle = pane.handle
        let cwd = tab.cwd
        services.registry.track(Task { @MainActor in
            do {
                let surface = try await Self.spawn(viewer, in: handle, workspace: workspace, cwd: cwd, connection: connection)
                // Placed once the tab exists, on the main actor: the placement closure is not Sendable.
                if target == nil {
                    AgentBesidePlacement.placed(invocation, pane: chatPane, controller: services.paneController(for: chatPane),
                                                services: services, then: nil)(surface)
                } else {
                    services.paneController(for: pane)?.selectWhenReported(surface: surface)
                }
                return nil
            } catch {
                return ActionWorkFailure("process-terminal", error)
            }
        })
        return true
    }

    /// Starts `viewer` as a new tab at the end of `pane`: `create-terminal` with its argv, which
    /// lands in `workspace`'s active pane, then moved to `pane` when it landed in another one.
    private static func spawn(_ viewer: AgentPaneProcessViewer, in pane: CmuxNextDaemon.PaneID, workspace: WorkspaceKey, cwd: String?,
                              connection: DaemonConnection) async throws -> SurfaceID {
        let created = try await connection.createTerminal(in: workspace, cwd: cwd, argv: viewer.argv, name: viewer.title,
                                                          env: viewer.environment)
        guard let surface = created.surface else { throw DaemonError.malformedResponse("create-terminal returned no surface") }
        if created.pane != pane { try await connection.moveTab(surface, to: pane, index: appendIndex) }
        return surface
    }

    /// The first pane of the scrolling column right of `chat` (for a chat in a dock, the strip's
    /// first column), as `cmux identify`'s `beside` names it; nil when there is none.
    static func besidePane(of chat: PaneModel, in store: DaemonStore) -> PaneModel? {
        guard let screen = store.workspace(containing: chat.handle)?.screens.first(where: { $0.panes.contains { $0 === chat } }),
              let index = screen.columns.firstIndex(where: { $0.layout.paneIDs.contains(chat.handle) }) else { return nil }
        let candidates = screen.columns[index].dock == nil ? screen.columns[(index + 1)...] : screen.columns[...]
        guard let column = candidates.first(where: { $0.dock == nil && !$0.layout.paneIDs.contains(chat.handle) }),
              let first = column.layout.paneIDs.first else { return nil }
        return screen.panes.first { $0.handle == first }
    }
}
