import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout

extension AppServices {
    /// Shows tab `id` the way a user's jump does (Go To in history, Search
    /// Tabs, a `cmux://` link): the window that lists its workspace comes
    /// forward (made key only while the app is active), the workspace,
    /// screen and tab are selected and its pane takes focus. Returns false
    /// when no connected machine has the tab.
    ///
    /// - Parameters:
    ///   - id: A daemon tab's id (`TabModel.id`), agent chat tabs included.
    ///   - intent: How the window comes forward; `.bringForward` leaves the
    ///     key window alone (a link opened in the background).
    @discardableResult
    func revealTab(_ id: String, intent: WindowActivation.Intent = .raise) -> Bool {
        let located = locateTabOnAnyMachine(id)
        guard let paneModel = located?.1,
              let workspace = daemon(for: paneModel).store.workspace(containing: paneModel.handle) else { return false }
        // A `tab_` link names a tab the strip may know by its first id.
        return showRevealed(located?.0.id ?? id, in: paneModel, workspace: workspace, intent: intent)
    }

    /// Shows tab `id` on the named machine, refusing a same-id tab on another machine.
    @discardableResult
    func revealTab(_ id: String, onMachine machineID: String, intent: WindowActivation.Intent = .raise) -> Bool {
        guard let daemon = machines.daemons.first(where: { $0.machineID == machineID }),
              let tab = daemon.store.tab(idOrResource: id),
              let pane = daemon.store.pane(holding: tab),
              let workspace = daemon.store.workspace(containing: pane.handle),
              machines.workspace(id: workspace.id)?.1 === daemon else { return false }
        return showRevealed(tab.id, in: pane, workspace: workspace, intent: intent)
    }

    /// Shows `tabID` in `pane`; a changed tab is timed (`debug.tab_switch`) in ``show(in:workspace:pane:tab:)``.
    private func showRevealed(_ tabID: String, in pane: PaneModel, workspace: WorkspaceModel, intent: WindowActivation.Intent) -> Bool {
        guard let window = windows.reveal(workspaceID: workspace.id) else { return false }
        show(in: window, workspace: workspace, pane: pane, tab: tabID)
        if let nsWindow = window.window { showJumpWindow(nsWindow, intent) }
        return true
    }

    /// The one jump (banner click, Go to Tab, tab.focus, Search Tabs, a link): content swapped in this turn, screen,
    /// tab, focus. The window's observer swaps it on a later turn, so a second banner clicked before that hop found no
    /// mounted pane and its select was dropped (notify-banner-click burst-click). Callers check view-change permission.
    func show(in window: WindowController, workspace: WorkspaceModel, screen: ScreenModel? = nil, pane: PaneModel?, tab: String?) {
        if window.content?.workspace !== workspace { window.showWorkspace(requested: workspace.id) } // idempotent
        let screen = screen ?? pane.flatMap { daemon(for: $0).store.location(of: $0)?.screen }
        if let screen, let content = window.content, content.workspace === workspace { ScreenCommands.select(LayoutScreenID(screen.id), in: content) }
        guard let pane else { return }
        guard let tab else { return window.focus.send(.focusPane(pane.id, workspace: workspace.id, source: .intent)) }
        let mounted = window.content?.pane(for: pane.handle).flatMap { $0.pane === pane ? $0 : nil } ?? paneController(for: pane), id = StripTabID(tab)
        if let mounted, mounted.stripModel.selectedID != id { DebugTabSwitch.began(mounted) }
        window.state.selection.jump(to: tab, in: pane.id, byPerson: ActionRunScope.isPersonsAction())
        window.focus.send(.selectTab(pane: pane.id, tab: tab, workspace: workspace.id, source: .intent))
        mounted?.select(id)
    }

    /// The pane with id `id` on any connected machine: its `PaneModel.id`,
    /// or its `pane_` resource id when the model was first seen without one
    /// (its id is then `pane:<handle>`).
    func pane(id: String) -> PaneModel? {
        machines.daemons.lazy.compactMap { $0.store.pane(idOrResource: id) }.first
    }
}

extension AppServices {
    /// Shows the tab that already shows agent session `session` of `harness` (`claude`, `codex`):
    /// the agent chat resuming it, else a live terminal running it (``DeepLink/agentTabs``).
    /// False when no tab shows it; nothing starts, resumes or attaches.
    func revealAgentSession(harness: String, session: String, intent: WindowActivation.Intent = .raise) -> Bool {
        revealedAgentSessionTab(harness: harness, session: session, intent: intent) != nil
    }

    /// ``revealAgentSession(harness:session:intent:)``, returning the tab it showed and whether that
    /// tab is the adopting agent chat.
    func revealedAgentSessionTab(harness: String, session: String,
                                 intent: WindowActivation.Intent = .raise) -> (tab: String, adopted: Bool)? {
        let adopted = agentTabs.tab(resuming: AgentPaneAdopt(harness: harness, agentSessionId: session))
        let tabs = DeepLink.agentTabs(harness: harness, session: session, adopted: adopted,
                                      harnessSessions: machines.daemons.flatMap(\.store.reachableAgentHarnessSessions))
        return tabs.first { revealTab($0, intent: intent) }.map { ($0, $0 == adopted) }
    }
}
