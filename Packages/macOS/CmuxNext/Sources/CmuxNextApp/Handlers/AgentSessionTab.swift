import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// `agent.openSessionTab` (CLI `agent open-tab`, MCP `app_agent_open_tab`): an acpmux session's
/// chat as a tab, through the shared ``AgentSessionTabOpener`` the sidebar's nested sub-sessions
/// and a chat's `chat.offer.open` use too. A tab that shows the session already is reused. Else it
/// opens beside the tab of session `beside` (its parent chat, say), else as a tab in the most
/// recently focused pane of `workspace`, else in the focused pane. Focus moves only when the run
/// may change the view (a person's run, or `focus: true`).
///
/// Its result: `tab` (the tab's id) and `reused` (whether that tab showed the session already).
enum AgentSessionTab {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agent.openSessionTab", run: { invocation in
            try open(invocation, context: context)
        })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let services = context.services, registry = context.services.registry
        let session = (invocation["session"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { throw ActionFailure(message: MiscHandlerStrings.sessionRequired) }
        let tabs = services.agentTabs
        guard tabs.canHostChat else { throw ActionFailure(message: MiscHandlerStrings.quickChatUnavailable) }
        let beside = invocation["beside"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = beside.flatMap { $0.isEmpty ? nil : tabs.tab(showing: $0) }
        let reused = tabs.tab(showing: session) != nil
        var fallback: (pane: PaneID, daemon: DaemonService)?
        if let ref = invocation["workspace"]?.targetValue?.id ?? invocation["workspace"]?.stringValue, !ref.isEmpty {
            guard let (workspace, daemon) = services.machines.workspace(id: ref) else {
                registry.refuseNotFound(RefusalStrings.noWorkspace(ref))
                return
            }
            let pane = workspace.screens.flatMap(\.panes).max { $0.focusedAt < $1.focusedAt }
            fallback = pane.map { ($0.handle, daemon) }
        } else if let pane = services.windows.active?.focusedPane {
            fallback = (pane.pane.handle, pane.daemon)
        }
        guard reused || anchor != nil || fallback != nil else { throw ActionFailure(message: MiscHandlerStrings.noPane) }
        let waiter = AgentSessionTabWaiter()
        let started = AgentSessionTabOpener(tabs: tabs).open(session, beside: anchor, fallback: fallback,
                                                             focus: invocation.allowsViewChange, onTab: waiter.finish)
        guard started else { throw ActionFailure(message: RefusalStrings.agentTabCreateFailed) }
        // task-owner: the action run; a capturing caller (socket, CLI) awaits the tab through the registry.
        registry.track(result: Task { @MainActor in
            guard let tab = await waiter.value() else {
                return .failure(ActionWorkFailure("agent.openSessionTab: the tab for session \(session) did not open"))
            }
            return .success(["tab": .string(tab), "reused": .bool(reused)])
        })
    }
}
