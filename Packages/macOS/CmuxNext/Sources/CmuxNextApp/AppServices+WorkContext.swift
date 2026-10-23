import CmuxNextDaemon
import CmuxNextFocus

/// The app's side of ``WorkContextTrail`` (NEW-WORK-INHERITS-CONTEXT): each window's settled focus
/// on a terminal or agent chat joins the trail, and new terminals and chats read it.
extension AppServices {
    /// A window's focus settled: the terminal or agent chat that has the keyboard joins the trail.
    func noteWorkFocus(_ state: FocusState, in controller: WindowController) {
        guard state.target == .content, let pane = state.pane, let tab = state.topology.pane(pane)?.selectedTab?.id,
              let workspace = state.topology.workspace,
              let entry = workEntry(tab, workspace: workspace, window: controller.state.id) else { return }
        workContext.record(entry)
    }

    /// Tab `tab` as a trail entry: a terminal, or an agent chat that is not a New Tab page.
    func workEntry(_ tab: String, workspace: String, window: String) -> WorkContextTrail.Entry? {
        let kind: WorkContextTrail.Kind
        if agentTabs.isAgentTab(tab) {
            guard !agentTabs.isNewTabPage(tab) else { return nil }
            kind = .chat
        } else if locateTab(tab)?.0.kind == .pty {
            kind = .terminal
        } else {
            return nil
        }
        return WorkContextTrail.Entry(tab: tab, workspace: workspace, window: window, kind: kind)
    }

    /// Whether `workspace` holds a terminal or agent chat of its own (focused or not).
    func holdsWork(_ workspace: WorkspaceModel) -> Bool {
        workspace.screens.contains { screen in
            screen.panes.contains { pane in pane.tabs.contains { $0.kind == .pty || agentTabs.isAgentTab($0.id) } }
        }
    }

    /// The first live value of the trail for a new terminal or chat beside `tab` in `pane` (the
    /// rule on ``WorkContextTrail``). Only for a pane of this Mac's daemon: the trail's folders and
    /// chats are this Mac's. `value` reads one candidate tab (nil skips it).
    func inheritedWork<Value>(besides tab: TabModel?, in pane: PaneModel?, kinds: Set<WorkContextTrail.Kind>,
                              value: (TabModel) -> Value?) -> Value? {
        let target = pane.map { self.daemon(for: $0) } ?? self.daemon
        guard target === self.daemon else { return nil }
        let workspace = pane.flatMap { target.store.workspace(containing: $0.handle) }
        let window = windows.active?.state.id
        let current = tab.flatMap { tab in workEntry(tab.id, workspace: workspace?.id ?? "", window: window ?? "") }
        return workContext.resolve(current: current, workspace: workspace?.id, window: window,
                                   workspaceHasWork: workspace.map { holdsWork($0) } ?? true, kinds: kinds) { entry in
            guard let (tab, pane) = locateTab(entry.tab), self.daemon(for: pane) === self.daemon else { return nil }
            return value(tab)
        }
    }
}
