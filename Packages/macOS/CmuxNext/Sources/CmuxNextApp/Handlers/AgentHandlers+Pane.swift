import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
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
        // The mount is awaited off the action's turn; the chat opens in one task of the run's completion.
        context.registry.trackWork(owner: "AgentHandlers.withAgentPane", on: context.services.mainWork) {
            await Self.waitForPaneController(in: workspace, context: context)
        } then: { result in
            guard case .success(let pane?) = result else {
                context.refuse(MiscHandlerStrings.noPane)
                return ActionWorkFailure(MiscHandlerStrings.noPane)
            }
            open(pane)
            return nil
        }
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
        var spawn = WorkspaceSpawn(cwd: seed.cwd)
        spawn.firstChat = seed
        let request = spawn, windows = services.windows
        // The creation is awaited off the action's turn; its failure is one task of the run's completion.
        context.registry.trackWork(owner: "AgentHandlers.chatWorkspaceOverTopPage", on: services.mainWork) {
            _ = try await windows.createWorkspace(request, on: daemon, into: windowID)
        } then: { result in
            guard case .failure(let error) = result else { return nil }
            daemon.logger.error("agent chat workspace over a top page failed: \(String(describing: error), privacy: .public)")
            return ActionWorkFailure("new agent chat: \(error)")
        }
        return true
    }

    /// How long a new chat waits for the active workspace's first pane to mount.
    static let paneMountLimit: Duration = .seconds(10)

    /// The first mounted pane of `workspace`, at once when one is mounted now, else nil after ``paneMountLimit``.
    @MainActor
    private static func waitForPaneController(in workspace: WorkspaceModel, context: AppActionContext) async -> PaneController? {
        // The store's panes are observable; mounted controllers are not, so
        // the mount generation stands in for them (`PaneMounts`).
        let services = context.services
        let mounted: @MainActor () -> PaneController? = {
            workspace.screens.flatMap(\.panes).lazy.compactMap(services.paneController(for:)).first
        }
        // One ServiceObservation reads again only when the panes or the mount generation change.
        await ObservedCondition(owner: "AgentHandlers.paneMount", .visible, on: services.mainWork)
            .until(timeout: paneMountLimit, deadlines: services.mainDeadlines) {
                _ = services.paneMounts.generation
                return mounted() != nil
            }
        return mounted()
    }
}
