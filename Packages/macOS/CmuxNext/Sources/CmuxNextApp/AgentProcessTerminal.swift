import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// A background task's terminal (`chat.processTerminal`, background-task-terminal-DESIGN.md): the
/// viewer runs in a new terminal tab of the column right of the chat, the column the chat's diff
/// and preview open in, selected there; with no column there it opens in the chat's pane and
/// moves into a new column (``AgentBesidePlacement``). Only a chat on this Mac's daemon: the
/// viewer reads this Mac's acpmux.
@MainActor
struct AgentProcessTerminal {
    let services: AppServices

    /// Opens `viewer` beside chat tab `chat`; false when the chat is not found or not on this Mac.
    func open(_ viewer: AgentPaneProcessViewer, beside chat: String) -> Bool {
        guard let (tab, chatPane) = services.locateTab(chat) else { return false }
        let daemon = services.machines.daemon(forTab: tab)
        guard daemon.isLocal, let connection = daemon.connection else { return false }
        let store = daemon.store
        let target = Self.besidePane(of: chatPane, in: store)
        let pane = target ?? chatPane
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: chat), origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = target == nil
        let controller = services.paneController(for: pane)
        let placed: @MainActor @Sendable (SurfaceID) -> Void = target == nil
            ? AgentBesidePlacement.placed(invocation, pane: chatPane, controller: services.paneController(for: chatPane), services: services, then: nil)
            : { [weak controller] surface in controller?.selectWhenReported(surface: surface) }
        let options = SpawnOptions(cwd: tab.cwd, argv: viewer.argv, name: viewer.title, env: viewer.environment,
                                   workspace: services.workspaceKey(of: pane))
        services.registry.track(Task { @MainActor in
            do {
                let created = try await connection.newTab(in: pane.handle, options: options)
                placed(created.surface)
                return nil
            } catch {
                return ActionWorkFailure("process-terminal", error)
            }
        })
        return true
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
